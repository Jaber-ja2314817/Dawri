import DawriCore
import SwiftUI

/// The one navigation stack, with the language applied above it. The stack has no `.id`, so a
/// language switch keeps the path and everything on it. S06 is a cover above the stack and inside
/// the same environment, so a switch re-renders it in place and cannot dismiss it.
struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let lang = model.language.lang
        NavigationStack(path: $model.path) {
            rootScreen
                .navigationDestination(for: Route.self) { RouteScreen(route: $0) }
        }
        .background(WindowProbe(bridge: model.direction))
        .background {
            // On a view of its own, so the transaction that stops the slide reaches only S06
            // and never the stack's own push.
            Color.clear
                .fullScreenCover(item: emergencyCover) { cover in
                    EmergencyCoverScreen(cover: cover)
                        #if DEBUG
                        .modifier(DemoCoverModifier())
                        #endif
                }
                .transaction { $0.disablesAnimations = true }
        }
        .environment(\.lang, lang)
        .environment(\.locale, lang.locale)
        .environment(\.layoutDirection, lang.layoutDirection)
        .tint(DS.Color.ink)
        .dynamicTypeSize(typeSizes)
        .accessibilityIdentifier("app-root")
        .task { await model.load() }
        #if DEBUG
        .modifier(DemoRootModifier())
        #endif
    }

    /// AX3 is what the app promises and reviews (iOS Design section 2). In DEBUG,
    /// `-demoTypeCap off` lifts the cap, so the Dynamic Type audit can tell text that stops at the
    /// cap from text that never scales.
    private var typeSizes: ClosedRange<DynamicTypeSize> {
        #if DEBUG
        if DemoLaunch.current?.argument("demoTypeCap") == "off" { return .xSmall ... .accessibility5 }
        #endif
        return .xSmall ... .accessibility3
    }

    /// The system never writes this: S06 has no swipe and no back, and only the model closes it.
    private var emergencyCover: Binding<EmergencyCover?> {
        Binding(get: { model.emergency }, set: { _ in })
    }

    @ViewBuilder
    private var rootScreen: some View {
        #if DEBUG
        if DemoLaunch.current?.showsGallery == true {
            ComponentGallery()
        } else {
            RouteScreen(route: model.root)
        }
        #else
        RouteScreen(route: model.root)
        #endif
    }
}

/// What each route shows, after the session guard.
struct RouteScreen: View {
    let route: Route

    @Environment(AppModel.self) private var model

    var body: some View {
        switch guardedRoute(route, isSignedIn: model.isSignedIn) {
        case .welcome:
            WelcomeScreen()
        case .login:
            LoginScreen()
        case .home:
            HomeScreen()
        case .who:
            WhoScreen()
        case .consent(let patientId):
            ConsentScreen(patientId: patientId)
        case .history:
            HistoryScreen()
        case .settings:
            SettingsScreen()
        case .visitRoot(let id):
            VisitGate(model: model, id: id, screen: nil) { _, _ in EmptyView() }
        case .visit(let id, let screen):
            VisitGate(model: model, id: id, screen: screen) { visit, watcher in
                VisitScreen(screen: screen, visit: visit, watcher: watcher)
            }
        }
    }
}

/// The visit screens, once the gate has passed one. The gate never passes `.emergency` here,
/// because that route is the cover, and `.home` is not a visit screen.
private struct VisitScreen: View {
    let screen: Screen
    let visit: Visit
    let watcher: VisitWatcher

    var body: some View {
        switch screen {
        case .chat: ChatScreen(visit: visit, watcher: watcher)
        case .emergency: EmergencyScreen(visit: visit, watcher: watcher)
        case .refill: RefillScreen(visit: visit, watcher: watcher)
        case .centre: CentreScreen(visit: visit, watcher: watcher)
        case .reserved: ReservedScreen(visit: visit, watcher: watcher)
        case .ticket: TicketScreen(visit: visit, watcher: watcher)
        case .complete: CompleteScreen(visit: visit, watcher: watcher)
        case .home: HomeScreen()
        }
    }
}
