/// Every place the phone app can be. The patient paths of frontend/src/router.tsx, plus Settings.
public enum Route: Sendable, Hashable {
    case welcome
    case login
    case home
    case who
    case consent(patientId: String)
    case history
    case settings
    /// `/visit/:id`, which goes straight on to the visit's canonical screen.
    case visitRoot(id: String)
    case visit(id: String, screen: Screen)
}

/// `pathFor` in stages.ts: a visit screen nests under the visit, and home leaves it.
public func routeFor(visitId: String, screen: Screen) -> Route {
    screen == .home ? .home : .visit(id: visitId, screen: screen)
}

/// `checkInPath` in frontend/src/lib/checkin.ts: straight to consent when there is nobody
/// else to choose.
public func checkInRoute(_ me: Me) -> Route {
    me.dependents.isEmpty ? .consent(patientId: me.patient.id) : .who
}

/// A visit route as VisitGate leaves it, once the visit has loaded. Other routes pass through.
public func gatedRoute(_ route: Route, visit: Visit) -> Route {
    switch route {
    case .visitRoot(let id):
        routeFor(visitId: id, screen: gatedScreen(for: visit, requested: nil))
    case .visit(let id, let screen):
        routeFor(visitId: id, screen: gatedScreen(for: visit, requested: screen))
    default:
        route
    }
}

/// `RequireSession` and `SignedOutOnly` in frontend/src/router.tsx. Settings has no web
/// counterpart and is open either way, because mode and server are chosen before login.
public func guardedRoute(_ route: Route, isSignedIn: Bool) -> Route {
    switch route {
    case .welcome, .login:
        isSignedIn ? .home : route
    case .home, .who, .consent, .history, .visitRoot, .visit:
        isSignedIn ? route : .login
    case .settings:
        route
    }
}
