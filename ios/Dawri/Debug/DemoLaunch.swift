#if DEBUG
import DawriCore
import Foundation
import SwiftUI

/// The DEBUG-only launch arguments, so a screenshot or a UI test needs no tapping. This is the
/// only place that stages from them, and all of it compiles out of Release. A screen's own hook
/// reads `DemoLaunch.current?.argument("demoSomething")` from its own file, under `#if DEBUG`.
///
///     -demoScreen s01...s12|chat|emergency|refill|centre|reserved|ticket|complete|consent|settings|gallery|live
///     -demoPage active|called|serving|between|stale|ended, with `live`: that state of the Live
///       Activity gallery, or every state with no page
///     -demoLang ar|en  -demoPatient <qid>  -demoStage <stage>  -demoConfirmed 0|1
///     -demoTheme light|dark  -demoPage <gallery page>  -demoSwitchTo ar|en  -demoControls 1
///     -demoPushAfter <seconds>, which opens S02, so a recording can catch the push
///     -demoSendText <sentence>, what the test control sends, in place of the patient's own line
///
///     -demoFreeze 1, staging on a fixed clock, so nothing moves under a screenshot
///     -demoFail route=code[:detail],...  by protocol method, every call
///     -demoFailOnce route=code[:detail],...  the same, first call only
///     -demoHold route,...  never answers, for loading states
///     -demoPatch noTicket,...  reshapes answers, see `DemoPatch`
///     -demoNoDriver 1, a service that does not conform to `DemoDriving`, as a clinic server is
///     -demoTicket called|serving  -demoChat opening|midway|summary  -demoExpiresIn <seconds>
///     -demoFor <patient id>, the visit is a dependent's  -demoHistory mixed
///     -demoRedFlag 1, opens S06 as chat would  -demoRecordLinks 1, links go to `debug-status`
///     -demoSignIn <qid>, who the test control signs in  -demoOverride 1, S06 sends the override
///     -demoClinic <url>, launch straight into Clinic server mode on that address, signed out,
///       as a relaunch after Connect would. The address must pass `ServerAddress`, or the launch
///       stops before any request. The service is `RemoteClinicService` inside `DemoClinicProxy`,
///       so `-demoFail visitUpdates=network` forces polling, with its token in memory only. With
///       `-demoServer` it is a stand-in with no network at all, see `DemoAccount`
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
    let frozen: Bool
    let ticketState: TicketState?
    let chat: DemoChatPoint?
    let expiresIn: TimeInterval?
    let dependent: String?
    let history: Bool
    let redFlag: Bool
    let recordsLinks: Bool
    let noDriver: Bool
    let faults: DemoFaults
    private let arguments: [String]

    /// Nil on a launch with none of these arguments, which is the normal path.
    static let current = DemoLaunch(arguments: ProcessInfo.processInfo.arguments)

    init?(arguments: [String]) {
        func value(_ name: String) -> String? {
            Self.value(of: name, in: arguments)
        }
        guard arguments.contains(where: { $0.hasPrefix("-demo") }) else { return nil }
        self.arguments = arguments
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
        frozen = value("demoFreeze") == "1"
        ticketState = value("demoTicket").flatMap(TicketState.init(rawValue:))
        chat = value("demoChat").flatMap(DemoChatPoint.init(rawValue:))
        expiresIn = value("demoExpiresIn").flatMap(TimeInterval.init)
        dependent = value("demoFor")
        history = value("demoHistory") == "mixed"
        redFlag = value("demoRedFlag") == "1"
        recordsLinks = value("demoRecordLinks") == "1"
        noDriver = value("demoNoDriver") == "1"
        faults = DemoFaults(
            fail: value("demoFail"), failOnce: value("demoFailOnce"), hold: value("demoHold"),
            patch: value("demoPatch"))
    }

    private static func value(of name: String, in arguments: [String]) -> String? {
        arguments.firstIndex(of: "-\(name)").flatMap { index in
            arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
        }
    }

    /// The value of `-name`, for a hook that a screen reads from its own file.
    func argument(_ name: String) -> String? {
        Self.value(of: name, in: arguments)
    }

    var showsGallery: Bool { screen == "gallery" }

    /// `-demoScreen live`: every Live Activity presentation, `LiveGallery`.
    var showsLiveGallery: Bool { screen == "live" }

    /// DEBUG launches never touch the saved language or the saved clinic, so they cannot change
    /// a normal launch. A language asked for here counts as the viewer's choice, or the record's
    /// language would replace it on the first `getMe`.
    @MainActor
    func makeModel() -> AppModel {
        let store = MemoryStore()
        if let lang {
            store.write(lang.rawValue, for: "dawri.lang")
            store.write("1", for: "dawri.lang.chosen")
        }
        let language = LanguageState(store: store)
        let settings = MemoryStore()

        let destination = Self.destinations[screen ?? ""]
        if let address = argument("demoClinic") {
            // Signed out, so only the screens that need no session can open.
            guard let base = ServerAddress.parse(address).url, let service = try? serverService(base) else {
                preconditionFailure("-demoClinic refused \(address) before any request")
            }
            let path = destination.flatMap { $0.needsSession ? nil : $0.route("") }.map { [$0] } ?? []
            return AppModel(
                service: service, language: language, isSignedIn: false, path: path, features: features,
                settings: settings, clinic: .server(base))
        }
        let wantsSession = patient != nil || history || (destination?.needsSession ?? false)
        guard wantsSession else {
            // Screens with no session have no visit, so their routes ignore the id.
            return AppModel(
                service: proxy(LocalClinicService(store: MemoryClinicStore())), language: language,
                isSignedIn: false, path: destination?.route("").map { [$0] } ?? [],
                features: features, settings: settings)
        }
        let stage = stage ?? destination?.stage ?? .triage
        let staged = waitForStaging(
            patientId: patientId(for: stage), stage: stage,
            confirmed: confirmed ?? destination?.confirmed ?? Self.confirmedByDefault(stage),
            language: lang?.rawValue)
        faults.setVisit(staged.visitId)
        let model = AppModel(
            service: proxy(staged.service), language: language, isSignedIn: true,
            path: destination?.route(staged.visitId).map { [$0] } ?? [], features: features,
            settings: settings)
        model.demoVisitId = staged.visitId
        if redFlag { model.showEmergency(visitId: staged.visitId, redFlag: true) }
        return model
    }

    /// The host for a DEBUG launch. It never touches the phone's saved settings or Keychain: the
    /// mode and address go to the launch's own memory store, the clinic on this phone is a fresh
    /// one in memory, and a server keeps its token in memory.
    @MainActor
    func makeHost() -> AppHost {
        let model = makeModel()
        let maker = ClinicMaker(
            language: model.language, settings: model.settings, features: features,
            local: { (proxy(LocalClinicService(store: MemoryClinicStore())), false) },
            server: { base, _ in (try serverService(base), false) })
        return AppHost(maker: maker, launch: model)
    }

    /// A clinic server for a DEBUG launch, signed out. With `-demoServer`, whose probe is a fake,
    /// a clinic in memory stands in for the server: it sends nothing anywhere and is not
    /// `DemoDriving`, as a real server is not. Otherwise the real `RemoteClinicService`, inside
    /// the proxy so the fault hooks reach it.
    func serverService(_ base: URL) throws -> any ClinicService {
        if argument("demoServer") != nil {
            return DemoClinicProxy(base: LocalClinicService(store: MemoryClinicStore()), faults: faults)
        }
        let remote = try RemoteClinicService(
            baseURL: base, transport: ClinicNetwork.transport, tokens: MemoryTokenStore())
        return DemoClinicProxy(base: remote, faults: faults)
    }

    /// Hooks that change an answer sit in the proxy, between the screens and the real engine.
    private func proxy(_ service: LocalClinicService) -> any ClinicService {
        noDriver
            ? DemoClinicProxy(base: service, faults: faults)
            : DemoDrivenClinicProxy(base: service, driver: service, faults: faults)
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
                let staged = try await walk(
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
    private func walk(
        patientId: String, stage: VisitStage, confirmed: Bool, language: String?
    ) async throws -> Staged {
        let store = MemoryClinicStore()
        let clock = stagingClock()
        if history {
            return try await LocalClinicService.stagedHistory(
                patientId: patient == nil ? "P002" : patientId, clock: clock, store: store,
                language: language)
        }
        let staged = try await LocalClinicService.staged(
            patientId: patientId, stage: stage == .cancelled && confirmed ? .intake : stage,
            confirmed: confirmed, clock: clock, store: store, language: language,
            dependent: dependent, ticketState: ticketState, chat: chat, expiresIn: expiresIn)
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
        let service = LocalClinicService(clock: clock, store: try MemoryClinicStore(state: state))
        let changed = try await service.getVisit(visitId: visitId)
        precondition(
            changed.stage == stage && changed.confirmedByPatient == confirmed,
            "The saved state did not reach the visit")
        return (service, visitId)
    }

    /// `-demoFreeze`: the launch's moment, for good.
    private func stagingClock() -> @Sendable () -> Date {
        guard frozen else { return { Date() } }
        let launched = Date()
        return { launched }
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
final class MemoryStore: KeyValueStore {
    private var values: [String: String] = [:]
    func read(_ key: String) -> String? { values[key] }
    func write(_ value: String, for key: String) { values[key] = value }
    func remove(_ key: String) { values[key] = nil }
}

/// The theme override, the timed language switch and the test controls. RootView applies this
/// through a call that compiles out with it. It sits outside the cover, so its environment
/// reaches S06 too.
struct DemoRootModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let demo = DemoLaunch.current
        content
            .preferredColorScheme(demo?.theme)
            .modifier(LiveProbeModifier())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if demo?.showsTestControls == true {
                    DemoControls()
                }
            }
            .modifier(DemoLinkRecorder(isOn: demo?.recordsLinks == true))
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

/// A cover hides everything beneath it, so S06 carries its own controls. In the inset, because
/// an overlay would sit on Call 999.
struct DemoCoverModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .modifier(LiveProbeModifier())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if DemoLaunch.current?.showsTestControls == true {
                    DemoControls()
                }
            }
    }
}

private struct DemoLinkRecorder: ViewModifier {
    let isOn: Bool

    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if isOn {
            content.environment(
                \.openURL,
                OpenURLAction { url in
                    model.demoStatus = "opened \(url.absoluteString)"
                    return .handled
                })
        } else {
            content
        }
    }
}

extension DemoLaunch {
    /// `debug-status` has to exist for a recorded link, with or without the other controls.
    fileprivate var showsTestControls: Bool {
        showsControls || recordsLinks
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
/// path and `debug-status` the last result. Only with `-demoControls 1`, and never in a
/// screenshot. Its state lives on the model, because S06's cover has a second copy of it.
private struct DemoControls: View {
    @Environment(AppModel.self) private var model

    /// One action at a time, in the order they were tapped, so two quick taps are two steps.
    private func run(_ action: @escaping @MainActor (String) async throws -> String) {
        guard let visitId = model.demoVisitId else { return }
        run { try await action(visitId) }
    }

    private func run(_ action: @escaping @MainActor () async throws -> String) {
        let previous = model.demoLastAction
        model.demoLastAction = Task {
            await previous?.value
            do {
                model.demoStatus = try await action()
            } catch {
                model.demoStatus = "failed \((error as? ClinicError)?.code ?? String(describing: error))"
            }
        }
    }

    /// The path, then the cover, which is where the emergency route lives.
    private var pathText: String {
        var entries = model.path.map { String(describing: $0) }
        if let cover = model.emergency {
            entries.append("emergency(\(cover.visitId), redFlag: \(cover.redFlag))")
        }
        return entries.joined(separator: " > ")
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
            Button("in") {
                run {
                    let qid = DemoLaunch.current?.argument("demoSignIn") ?? "DEMO-10003"
                    try await model.signIn(qid: qid, otp: "0000")
                    return "signed in"
                }
            }
            .accessibilityIdentifier("debug-sign-in")
            Button("out") {
                model.signOut()
            }
            .accessibilityIdentifier("debug-sign-out")
            Button("push") {
                model.open(.settings)
            }
            .accessibilityIdentifier("debug-push")
            Button("read") {
                run { visitId in try await read(visitId) }
            }
            .accessibilityIdentifier("debug-read")
            Text(verbatim: model.demoStatus)
                .font(.caption2)
                .accessibilityIdentifier("debug-status")
            Text(verbatim: pathText)
                .font(.caption2)
                .accessibilityIdentifier("debug-path")
            Text(verbatim: "\(model.language.lang.rawValue) \(model.me?.patient.id ?? "-")")
                .font(.caption2)
                .accessibilityIdentifier("debug-session")
            Text(verbatim: String(model.demoSkeletons))
                .font(.caption2)
                .accessibilityIdentifier("debug-skeletons")
            Text(verbatim: String(model.demoSwipeWaits))
                .font(.caption2)
                .accessibilityIdentifier("debug-swipe-waits")
            TimelineView(.periodic(from: .now, by: 0.25)) { _ in
                Text(verbatim: DemoLaunch.current?.faults.callCounts ?? "")
                    .font(.caption2)
                    .accessibilityIdentifier("debug-calls")
            }
        }
        .padding(DS.Space.s)
        .frame(minHeight: DS.Size.minTarget)
        .background(DS.Color.surface)
    }

    /// What the screens would be told, through the proxy, on one line.
    private func read(_ visitId: String) async throws -> String {
        let service = model.service
        let visit = try await service.getVisit(visitId: visitId)
        let centres = try await service.listCentres(
            service: (visit.service ?? .gp).rawValue, visitId: visitId, lat: nil, lng: nil)
        let rows = try await service.listVisits()
        let left = visit.ticket?.expiresAt.flatMap(Timestamp.date(from:))
            .map { Int($0.timeIntervalSinceNow) }
        let parts: [(String, String?)] = [
            ("stage", visit.stage.rawValue), ("patient", visit.patientId),
            ("number", visit.ticket?.number), ("state", visit.ticket?.state.rawValue),
            ("ahead", visit.ticket?.peopleAhead.map(String.init)),
            ("wait", visit.ticket?.estWaitMin.map(String.init)),
            ("left", left.map(String.init)), ("meds", String(visit.medicines.en.count)),
            ("refill", visit.refill?.medicine), ("user", String(visit.chat.messages.count { $0.role == .user })),
            ("intake", String(visit.intake != nil)), ("harm", visit.emergency.map { String($0.selfHarm) }),
            ("rows", rows.map(\.stage.rawValue).sorted().joined(separator: "+")),
            ("centres", String(centres.centres.count)), ("default", centres.defaultCentreId),
            ("fallback", String(centres.serviceFallback)), ("suggestion", centres.suggestion?.centreId),
            ("centreWait", centres.centres.first?.waitMin.map(String.init)),
            ("driver", String(model.demoDriver != nil)),
        ]
        return parts.map { "\($0.0)=\($0.1 ?? "nil")" }.joined(separator: " ")
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
        guard let demo = model.demoDriver else { return }
        while try await model.service.getVisit(visitId: visitId).stage == start {
            guard case .moved = try await demo.demoNextStep(visitId: visitId) else { return }
        }
    }
}
#endif
