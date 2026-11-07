import DawriCore
import SwiftUI

/// The one navigation stack, with the language applied above it. The stack has no `.id`, so a
/// language switch keeps the path and everything on it.
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
        .environment(\.lang, lang)
        .environment(\.locale, lang.locale)
        .environment(\.layoutDirection, lang.layoutDirection)
        .tint(DS.Color.ink)
        .dynamicTypeSize(.xSmall ... .accessibility3)
        .accessibilityIdentifier("app-root")
        .task { await model.load() }
        #if DEBUG
        .modifier(DemoRootModifier())
        #endif
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
            PlaceholderScreen(id: "login", titleKey: "login.title")
        case .home:
            PlaceholderScreen(id: "home", titleKey: "screen.home")
        case .who:
            PlaceholderScreen(id: "who", titleKey: "who.title")
        case .consent:
            PlaceholderScreen(id: "consent", titleKey: "consent.title")
        case .history:
            PlaceholderScreen(id: "history", titleKey: "history.title")
        case .settings:
            PlaceholderScreen(id: "settings", titleKey: "settings.title")
        case .visitRoot(let id):
            VisitGate(id: id, screen: nil) { _, _ in EmptyView() }
        case .visit(let id, let screen):
            VisitGate(id: id, screen: screen) { _, _ in
                PlaceholderScreen(
                    id: screen.rawValue, titleKey: "screen.\(screen.rawValue)",
                    tone: screen == .emergency ? .emergency : .default)
            }
        }
    }
}
