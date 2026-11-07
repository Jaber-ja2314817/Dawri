import Testing
@testable import DawriCore

private func stage(_ status: VisitStatus) -> VisitStage { status.stage }

private struct Row: Sendable, CustomTestStringConvertible {
    let status: VisitStatus
    let confirmed: Bool
    let screens: [Screen]
    var testDescription: String { "\(status.rawValue), confirmed \(confirmed)" }
}

private let expected: [Row] = [
    Row(status: .intake, confirmed: false, screens: [.chat]),
    Row(status: .intake, confirmed: true, screens: [.centre]),
    Row(status: .redirectedEmergency, confirmed: false, screens: [.emergency]),
    Row(status: .deflectedRefill, confirmed: false, screens: [.refill]),
    Row(status: .reserved, confirmed: true, screens: [.reserved]),
    Row(status: .expired, confirmed: true, screens: [.reserved, .centre]),
    Row(status: .inTriage, confirmed: true, screens: [.ticket]),
    Row(status: .inDoctor, confirmed: true, screens: [.ticket]),
    Row(status: .inPharmacy, confirmed: true, screens: [.ticket]),
    Row(status: .completed, confirmed: true, screens: [.complete]),
    Row(status: .cancelled, confirmed: false, screens: [.home]),
]

@Suite("screensFor, every row of stages.test.ts")
struct ScreensForTests {
    @Test(arguments: expected)
    fileprivate func table(row: Row) {
        #expect(
            screensFor(stage: stage(row.status), confirmedByPatient: row.confirmed) == row.screens)
    }

    @Test func `covers all 10 statuses`() {
        #expect(Set(expected.map(\.status)).count == 10)
        #expect(VisitStatus.allCases.count == 10)
    }

    @Test(arguments: VisitStatus.allCases.filter { $0 != .intake })
    func `never offers chat, confirmed or not`(status: VisitStatus) {
        #expect(!screensFor(stage: stage(status), confirmedByPatient: true).contains(.chat))
        #expect(!screensFor(stage: stage(status), confirmedByPatient: false).contains(.chat))
    }

    @Test func `never offers chat on a confirmed intake`() {
        #expect(!screensFor(stage: .intake, confirmedByPatient: true).contains(.chat))
    }
}

@Suite("routeFor, the port of pathFor")
struct RouteForTests {
    @Test func `nests visit screens under the visit`() {
        #expect(routeFor(visitId: "V1", screen: .ticket) == .visit(id: "V1", screen: .ticket))
        #expect(routeFor(visitId: "V1", screen: .chat) == .visit(id: "V1", screen: .chat))
    }

    @Test func `sends home out of the visit`() {
        #expect(routeFor(visitId: "V1", screen: .home) == .home)
    }
}

@Suite("checkInRoute, the port of checkInPath")
struct CheckInTests {
    @Test func `someone with dependents picks who the visit is for`() throws {
        #expect(checkInRoute(try Fixture.decode(Me.self, "me_with_dependents")) == .who)
    }

    @Test func `someone alone goes straight to consent`() throws {
        let me = try Fixture.decode(Me.self, "me_no_dependents")
        #expect(me.dependents.isEmpty)
        #expect(checkInRoute(me) == .consent(patientId: "P003"))
    }
}

@Suite("The VisitGate redirect rule")
struct VisitGateTests {
    @Test(arguments: expected)
    fileprivate func `a listed screen is shown`(row: Row) {
        for screen in row.screens {
            #expect(gatedScreen(
                stage: stage(row.status), confirmedByPatient: row.confirmed, requested: screen
            ) == screen)
        }
    }

    @Test(arguments: expected)
    fileprivate func `anything else goes to the canonical screen`(row: Row) {
        for screen in Screen.allCases where !row.screens.contains(screen) {
            #expect(gatedScreen(
                stage: stage(row.status), confirmedByPatient: row.confirmed, requested: screen
            ) == row.screens[0])
        }
    }

    @Test(arguments: expected)
    fileprivate func `no request goes to the canonical screen`(row: Row) {
        #expect(gatedScreen(
            stage: stage(row.status), confirmedByPatient: row.confirmed, requested: nil
        ) == row.screens[0])
    }

    @Test func `Back cannot return to chat after an emergency`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_emergency")
        #expect(gatedScreen(for: visit, requested: .chat) == .emergency)
    }

    @Test func `a chat box stays off a completed visit`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_completed")
        #expect(gatedScreen(for: visit, requested: .chat) == .complete)
    }

    @Test func `an expired visit may pick a new centre`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_expired")
        #expect(gatedScreen(for: visit, requested: .centre) == .centre)
        #expect(gatedScreen(for: visit, requested: nil) == .reserved)
    }

    @Test func `a visit root resolves to its canonical screen`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_triage")
        #expect(gatedRoute(.visitRoot(id: visit.visitId), visit: visit)
            == .visit(id: visit.visitId, screen: .ticket))
    }

    @Test func `a cancelled visit leaves for home`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_cancelled")
        #expect(gatedRoute(.visitRoot(id: visit.visitId), visit: visit) == .home)
        #expect(gatedRoute(.visit(id: visit.visitId, screen: .chat), visit: visit) == .home)
    }

    @Test func `routes outside a visit pass through`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_triage")
        #expect(gatedRoute(.history, visit: visit) == .history)
    }
}

@Suite("RequireSession and SignedOutOnly")
struct SessionGuardTests {
    private static let needSession: [Route] = [
        .home, .who, .consent(patientId: "P001"), .history, .visitRoot(id: "V1"),
        .visit(id: "V1", screen: .ticket),
    ]

    @Test(arguments: needSession)
    func `a signed-out patient goes to login`(route: Route) {
        #expect(guardedRoute(route, isSignedIn: false) == .login)
    }

    @Test(arguments: needSession)
    func `a signed-in patient stays`(route: Route) {
        #expect(guardedRoute(route, isSignedIn: true) == route)
    }

    @Test(arguments: [Route.welcome, .login])
    func `the signed-out screens send a session home`(route: Route) {
        #expect(guardedRoute(route, isSignedIn: true) == .home)
        #expect(guardedRoute(route, isSignedIn: false) == route)
    }

    @Test func `Settings is open either way`() {
        #expect(guardedRoute(.settings, isSignedIn: true) == .settings)
        #expect(guardedRoute(.settings, isSignedIn: false) == .settings)
    }
}
