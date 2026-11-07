import DawriCore
import Foundation
import Observation

/// The app's state above the navigation stack: the clinic behind the protocol, the session, the
/// language, the health result and the path. Language, path and drafts live here so a language
/// switch cannot lose them.
@MainActor
@Observable
final class AppModel {
    @ObservationIgnored let service: any ClinicService
    let language: LanguageState
    @ObservationIgnored let direction: DirectionBridge

    private(set) var isSignedIn: Bool
    private(set) var health: Health?
    var path: [Route]
    /// Set when a visit vanished, so S03 can say so, as the web's `demoReset` route state does.
    private(set) var showsDemoReset = false

    init(
        service: any ClinicService, language: LanguageState, isSignedIn: Bool = false,
        path: [Route] = []
    ) {
        self.service = service
        self.language = language
        self.isSignedIn = isSignedIn
        self.path = path
        self.direction = DirectionBridge(initial: language.lang)
    }

    /// The normal launch. Phase 1 uses the stub. `LocalClinicService` replaces it here, and
    /// nothing else in the app changes, because screens only know the protocol.
    static func launch() -> AppModel {
        #if DEBUG
        if let demo = DemoLaunch.current { return demo.makeModel() }
        #endif
        return AppModel(
            service: StubClinicService(), language: LanguageState(store: UserDefaults.standard))
    }

    /// `.welcome` is the stack's root before login and `.home` after.
    var root: Route { isSignedIn ? .home : .welcome }

    /// `footer.ai` shows whenever the AI mode is simulated, which is always in this app, so it
    /// stays up while the first health read is on its way.
    var showsSimulatedLine: Bool {
        (health?.aiMode ?? .simulated) == .simulated
    }

    func load() async {
        isSignedIn = await service.isSignedIn
        health = try? await service.health()
    }

    // Navigation

    /// A push, through the session guards of the web's router.
    func open(_ route: Route) {
        let guarded = guardedRoute(route, isSignedIn: isSignedIn)
        if guarded == root {
            path.removeAll()
        } else if path.last != guarded {
            path.append(guarded)
        }
    }

    /// The web's `navigate(..., { replace: true })`. The old entry goes, so Back and swipe-back
    /// can never return to a screen the visit has moved past. A stage that moves on during a
    /// swipe waits for the swipe to end, and does nothing if the swipe took that screen away.
    func replace(_ route: Route, with next: Route) async {
        while direction.isSwipingBack {
            try? await Task.sleep(for: .milliseconds(100))
            if Task.isCancelled { return }
        }
        guard let index = path.lastIndex(of: route) else { return }
        if next == root {
            path.removeSubrange(index...)
        } else {
            path.replaceSubrange(index..., with: [next])
        }
    }

    /// What a 404 from `getVisit` does: a demo reset took the visit, so go home and say so.
    func visitGone() {
        path.removeAll()
        showsDemoReset = true
    }

    // Language

    /// Any time, with no restart. The path stays exactly as it is.
    func switchLanguage(to next: Lang) {
        direction.crossfade {
            language.setLang(next)
            direction.apply(next)
        }
    }
}
