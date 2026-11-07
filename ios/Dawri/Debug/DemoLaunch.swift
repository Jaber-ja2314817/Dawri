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
    }

    var showsGallery: Bool { screen == "gallery" }

    /// DEBUG launches never touch the saved language, so they cannot change a normal launch.
    @MainActor
    func makeModel() -> AppModel {
        let store = MemoryStore()
        if let lang { store.write(lang.rawValue, for: "dawri.lang") }
        let language = LanguageState(store: store)
        let visitId = StubClinicService.startingVisitId

        let destination = Self.destinations[screen ?? ""]
        let wantsSession = patient != nil || (destination?.needsSession ?? false)
        guard wantsSession else {
            return AppModel(
                service: StubClinicService(), language: language, isSignedIn: false,
                path: destination?.route(visitId).map { [$0] } ?? [])
        }
        let stage = stage ?? destination?.stage ?? .triage
        let service = StubClinicService(
            patientId: patientId, stage: stage,
            confirmedByPatient: confirmed ?? destination?.confirmed ?? Self.confirmedByDefault(stage))
        return AppModel(
            service: service, language: language, isSignedIn: true,
            path: destination?.route(visitId).map { [$0] } ?? [])
    }

    /// `DEMO-10003` is P003, the same numbering as the seeded patients.
    private var patientId: String {
        guard let patient else { return "P001" }
        return patient.hasPrefix("P") ? patient : "P\(patient.suffix(3))"
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

/// Lets a UI test move a stub visit, with `debug-path` reporting the path. Only with
/// `-demoControls 1`, and never in a screenshot.
private struct DemoControls: View {
    @Environment(AppModel.self) private var model

    private var visitId: String { StubClinicService.startingVisitId }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button("send") {
                Task { _ = try? await model.service.sendChat(visitId: visitId, text: "demo") }
            }
            .accessibilityIdentifier("debug-send-chat")
            Button("advance") {
                Task { try? await (model.service as? StubClinicService)?.advance(visitId: visitId) }
            }
            .accessibilityIdentifier("debug-advance")
            Button("forget") {
                model.visitGone()
            }
            .accessibilityIdentifier("debug-forget-visit")
            Text(verbatim: model.path.map { String(describing: $0) }.joined(separator: " > "))
                .font(.caption2)
                .accessibilityIdentifier("debug-path")
        }
        .padding(DS.Space.s)
        .frame(minHeight: DS.Size.minTarget)
        .background(DS.Color.surface)
    }
}
#endif
