#if DEBUG
import DawriCore
import Foundation
import SwiftUI

/// The DEBUG-only launch arguments, so a screenshot or a UI test needs no tapping. This is the
/// only place that reads them, and all of it compiles out of Release.
///
///     -demoScreen s01...s12|chat|emergency|refill|centre|reserved|ticket|complete|consent|settings|gallery
///     -demoLang ar|en  -demoPatient <qid>  -demoStage <stage>  -demoConfirmed 0|1
///     -demoTheme light|dark  -demoPage <gallery page>  -demoSwitchTo ar|en  -demoControls 1
///     -demoPushAfter <seconds>, which opens S02, so a recording can catch the push
///     -demoSendText <sentence>, what the test control sends, in place of the patient's own line
struct DemoLaunch: Sendable {
    let screen: String?
    let lang: Lang?
    let patient: String?
    let stage: VisitStage?
    let confirmed: Bool?
    let theme: ColorScheme?
    let galleryPage: Int?
    let switchTo: Lang?
    let showsControls: Bool
    let pushAfter: Double?
    let sendText: String?

    /// Nil on a launch with none of these arguments, which is the normal path.
    static let current = DemoLaunch(arguments: ProcessInfo.processInfo.arguments)

    init?(arguments: [String]) {
        func value(_ name: String) -> String? {
            arguments.firstIndex(of: "-\(name)").flatMap { index in
                arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
            }
        }
        guard arguments.contains(where: { $0.hasPrefix("-demo") }) else { return nil }
        screen = value("demoScreen")?.lowercased()
        lang = value("demoLang").flatMap(Lang.init(rawValue:))
        patient = value("demoPatient")
        stage = value("demoStage").flatMap(VisitStage.init(rawValue:))
        confirmed = value("demoConfirmed").map { $0 == "1" }
        theme = value("demoTheme").map { $0 == "dark" ? .dark : .light }
        galleryPage = value("demoPage").flatMap(Int.init)
        switchTo = value("demoSwitchTo").flatMap(Lang.init(rawValue:))
        showsControls = value("demoControls") == "1"
        pushAfter = value("demoPushAfter").flatMap(Double.init)
        sendText = value("demoSendText")
    }

    var showsGallery: Bool { screen == "gallery" }

    /// DEBUG launches never touch the saved language or the saved clinic, so they cannot change
    /// a normal launch.
    @MainActor
    func makeModel() -> AppModel {
        let store = MemoryStore()
        if let lang { store.write(lang.rawValue, for: "dawri.lang") }
        let language = LanguageState(store: store)

        let destination = Self.destinations[screen ?? ""]
        let wantsSession = patient != nil || (destination?.needsSession ?? false)
        guard wantsSession else {
            // Screens with no session have no visit, so their routes ignore the id.
            return AppModel(
                service: LocalClinicService(store: MemoryClinicStore()), language: language,
                isSignedIn: false, path: destination?.route("").map { [$0] } ?? [])
        }
        let stage = stage ?? destination?.stage ?? .triage
        let staged = waitForStaging(
            patientId: patientId(for: stage), stage: stage,
            confirmed: confirmed ?? destination?.confirmed ?? Self.confirmedByDefault(stage),
            language: lang?.rawValue)
        let model = AppModel(
            service: staged.service, language: language, isSignedIn: true,
            path: destination?.route(staged.visitId).map { [$0] } ?? [])
        model.demoVisitId = staged.visitId
        return model
    }

    private typealias Staged = (service: LocalClinicService, visitId: String)

    /// The first frame needs the finished model and staging is async, so the launch waits here.
    /// This cannot deadlock: the clinic is an actor off the main thread, and nothing in it needs
    /// the main actor. A launch that asks for what cannot be staged stops with the reason.
    private func waitForStaging(
        patientId: String, stage: VisitStage, confirmed: Bool, language: String?
    ) -> Staged {
        let done = DispatchSemaphore(value: 0)
        // The semaphore orders the write before the read.
        nonisolated(unsafe) var outcome: Result<Staged, any Error>?
        Task.detached(priority: .userInitiated) {
            do {
                let staged = try await Self.stage(
                    patientId: patientId, stage: stage, confirmed: confirmed, language: language)
                outcome = .success(staged)
            } catch {
                outcome = .failure(error)
            }
            done.signal()
        }
        done.wait()
        switch outcome {
        case .success(let staged):
            return staged
        case .failure(let error):
            preconditionFailure("Cannot stage \(patientId) at \(stage.rawValue): \(error)")
        case nil:
            preconditionFailure("Staging signalled without a result")
        }
    }

    /// `staged` walks the real engine, so past intake the flag is the one a real visit has. The
    /// gate tests also need the other value, to prove chat is never offered whatever the flag
    /// says. No route reaches that, so it is set in the saved state and a service is built from
    /// it, which reads it back through the same `getVisit` as everything else.
    ///
    /// A visit cancelled at once has no chat row to hold the flag, so the confirmed one starts
    /// from a confirmed intake. `staged` cancels the same way, because no route cancels a visit.
    private static func stage(
        patientId: String, stage: VisitStage, confirmed: Bool, language: String?
    ) async throws -> Staged {
        let store = MemoryClinicStore()
        let staged = try await LocalClinicService.staged(
            patientId: patientId, stage: stage == .cancelled && confirmed ? .intake : stage,
            confirmed: confirmed, store: store, language: language)
        let visitId = staged.visitId
        let reached = try await staged.service.getVisit(visitId: visitId)
        guard reached.stage != stage || reached.confirmedByPatient != confirmed else { return staged }

        guard var state = store.load() else {
            preconditionFailure("A staged clinic always has saved state")
        }
        state.chats[visitId]?.confirmedByPatient = confirmed
        if stage == .cancelled, let row = state.clinic.visits.firstIndex(where: { $0.id == visitId }) {
            state.clinic.visits[row].status = .cancelled
        }
        let service = LocalClinicService(store: try MemoryClinicStore(state: state))
        let changed = try await service.getVisit(visitId: visitId)
        precondition(
            changed.stage == stage && changed.confirmedByPatient == confirmed,
            "The saved state did not reach the visit")
        return (service, visitId)
    }

    /// `DEMO-10003` is P003, the same numbering as the seeded patients. With no patient named,
    /// the refill route needs someone with active medicines, which Fatima has none of.
    private func patientId(for stage: VisitStage) -> String {
        guard let patient else { return stage == .refill ? "P002" : "P001" }
        return patient.hasPrefix("P") ? patient : "P\(patient.suffix(3))"
    }

    /// What the test control sends: the sentence asked for, or the patient's own opening line.
    func firstMessage(lang: Lang) -> String {
        sendText ?? DemoScript.opening(patientId: patientId(for: .intake), lang: lang)
    }

    private static func confirmedByDefault(_ stage: VisitStage) -> Bool {
        switch stage {
        case .intake, .emergency, .refill, .cancelled: false
        default: true
        }
    }

    private struct Destination: Sendable {
        let needsSession: Bool
        var stage: VisitStage?
        /// S08 is the one screen whose stage alone does not reach it: a confirmed intake.
        var confirmed: Bool?
        let route: @Sendable (String) -> Route?
    }

    private static func visit(
        _ screen: Screen, _ stage: VisitStage, confirmed: Bool? = nil
    ) -> Destination {
        Destination(needsSession: true, stage: stage, confirmed: confirmed) {
            .visit(id: $0, screen: screen)
        }
    }

    private static let destinations: [String: Destination] = {
        let welcome = Destination(needsSession: false) { _ in nil }
        let home = Destination(needsSession: true) { _ in nil }
        let chat = visit(.chat, .intake)
        let emergency = visit(.emergency, .emergency)
        let refill = visit(.refill, .refill)
        let centre = visit(.centre, .intake, confirmed: true)
        let reserved = visit(.reserved, .reserved)
        let ticket = visit(.ticket, .triage)
        let complete = visit(.complete, .completed)
        return [
            "s01": welcome, "gallery": welcome,
            "s02": Destination(needsSession: false) { _ in .login },
            "s03": home,
            "s04": Destination(needsSession: true) { _ in .who },
            "consent": Destination(needsSession: true) { _ in .consent(patientId: "P001") },
            "s05": chat, "chat": chat,
            "s06": emergency, "emergency": emergency,
            "s07": refill, "refill": refill,
            "s08": centre, "centre": centre,
            "s09": reserved, "reserved": reserved,
            "s10": ticket, "ticket": ticket,
            "s11": complete, "complete": complete,
            "s12": Destination(needsSession: true) { _ in .history },
            "settings": Destination(needsSession: false) { _ in .settings },
        ]
    }()
}

/// Keeps DEBUG launches out of the phone's real settings.
private final class MemoryStore: KeyValueStore {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, for key: String) { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}

/// The theme override, the timed language switch and the test controls. RootView applies this
/// through a call that compiles out with it.
struct DemoRootModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let demo = DemoLaunch.current
        content
            .preferredColorScheme(demo?.theme)
            .overlay(alignment: .bottom) {
                if demo?.showsControls == true {
                    DemoControls()
                }
            }
            .task {
                guard let next = demo?.switchTo else { return }
                try? await Task.sleep(for: .seconds(1.2))
                model.switchLanguage(to: next)
            }
            .task {
                guard let seconds = demo?.pushAfter else { return }
                try? await Task.sleep(for: .seconds(seconds))
                model.open(.login)
            }
    }
}

/// The sentences the web demo uses. The clinic reads them, so nothing here decides an outcome.
private enum DemoScript {
    static func opening(patientId: String, lang: Lang) -> String {
        switch (patientId, lang) {
        case ("P002", .ar): "أبي حبوب الضغط المعتادة"
        case ("P002", .en): "I need my usual blood pressure tablets."
        case ("P003", .ar): "عندي ألم في الصدر ينتشر إلى ذراعي"
        case ("P003", .en): "Chest pain going to my left arm."
        default: answers(lang)[0]
        }
    }

    /// A whole chat from the opening question, on the same path as `staged`.
    static func answers(_ lang: Lang) -> [String] {
        lang == .ar
            ? ["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"]
            : ["I have a fever and cough for three days", "6", "panadol", "no"]
    }

    static func decline(_ lang: Lang) -> String {
        lang == .ar ? "لا" : "no"
    }
}

/// Lets a UI test walk a staged visit through the real service, with `debug-path` reporting the
/// path and `debug-status` the last result. Only with `-demoControls 1`, and never in a screenshot.
private struct DemoControls: View {
    @Environment(AppModel.self) private var model
    @State private var status = "idle"
    @State private var last: Task<Void, Never>?

    /// One action at a time, in the order they were tapped, so two quick taps are two steps.
    private func run(_ action: @escaping @MainActor (String) async throws -> String) {
        guard let visitId = model.demoVisitId else { return }
        let previous = last
        last = Task {
            await previous?.value
            do {
                status = try await action(visitId)
            } catch {
                status = "failed \((error as? ClinicError)?.code ?? String(describing: error))"
            }
        }
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button("send") {
                run { visitId in try await send(visitId) }
            }
            .accessibilityIdentifier("debug-send-chat")
            Button("advance") {
                run { visitId in try await advance(visitId) }
            }
            .accessibilityIdentifier("debug-advance")
            Button("forget") {
                model.visitGone()
            }
            .accessibilityIdentifier("debug-forget-visit")
            Text(verbatim: status)
                .font(.caption2)
                .accessibilityIdentifier("debug-status")
            Text(verbatim: model.path.map { String(describing: $0) }.joined(separator: " > "))
                .font(.caption2)
                .accessibilityIdentifier("debug-path")
        }
        .padding(DS.Space.s)
        .frame(minHeight: DS.Size.minTarget)
        .background(DS.Color.surface)
    }

    private func send(_ visitId: String) async throws -> String {
        let lang = model.language.lang
        let text = DemoLaunch.current?.firstMessage(lang: lang) ?? DemoScript.answers(lang)[0]
        let reply = try await model.service.sendChat(visitId: visitId, text: text)
        return "\(reply.status.rawValue) \(reply.aiSource)"
    }

    /// One stage on, as a patient and the demo clinic would take it.
    private func advance(_ visitId: String) async throws -> String {
        let service = model.service
        let visit = try await service.getVisit(visitId: visitId)
        switch visit.stage {
        case .intake where !visit.confirmedByPatient:
            try await finishChat(visitId)
            _ = try await service.confirmIntake(visitId: visitId, service: nil)
        case .intake, .expired:
            let centres = try await service.listCentres(
                service: (visit.service ?? .gp).rawValue, visitId: visitId, lat: nil, lng: nil)
            guard let centre = centres.defaultCentreId else {
                throw ClinicError(status: 409, code: "no_default_centre", message: "No centre.")
            }
            _ = try await service.reserve(visitId: visitId, centreId: centre)
        case .reserved:
            _ = try await service.arrive(visitId: visitId, body: .button)
        case .triage, .doctor, .pharmacy:
            try await walkDemoClinic(visitId, from: visit.stage)
        case .emergency, .refill, .completed, .cancelled:
            break
        }
        return try await service.getVisit(visitId: visitId).stage.rawValue
    }

    private func finishChat(_ visitId: String) async throws {
        let lang = model.language.lang
        let decline = DemoScript.decline(lang)
        for line in DemoScript.answers(lang) + Array(repeating: decline, count: 4) {
            let reply = try await model.service.sendChat(visitId: visitId, text: line)
            if reply.done { return }
        }
    }

    private func walkDemoClinic(_ visitId: String, from start: VisitStage) async throws {
        guard let demo = model.service as? any DemoDriving else { return }
        while try await model.service.getVisit(visitId: visitId).stage == start {
            guard case .moved = try await demo.demoNextStep(visitId: visitId) else { return }
        }
    }
}
#endif
