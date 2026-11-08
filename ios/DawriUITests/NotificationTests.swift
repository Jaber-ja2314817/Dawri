import XCTest

/// Local notifications on the clinic on this phone, read through the DEBUG probe, with the real
/// `UNUserNotificationCenter` behind `-demoNotify on`. Every launch is on a frozen demo clock, so
/// only Demo: next step moves a visit and the plan stays where the probe reads it.
///
/// The system keeps the notification permission per install, and `simctl privacy` cannot reset
/// it. So the prompt itself shows only on the first of these runs after the app is installed
/// fresh: `xcrun simctl uninstall <Dawri Build> com.jaber.dawri` before the run. On a later run
/// the permission is already given, and each test says which case it met and checks the rest.
final class NotificationTests: XCTestCase {
    private let fatima = "DEMO-10001"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func start(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + [
            "-demoLang", "en", "-demoPatient", fatima, "-demoFreeze", "1", "-demoLiveProbe", "1",
        ]
        app.launch()
        return app
    }

    /// The system's permission alert, if it is up.
    @MainActor
    private var permissionAlert: XCUIElement {
        XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
    }

    /// Fatima on S09 with notifications on, then I'm here, accepting the prompt when it comes.
    /// Returns the permission the probe read before the arrival.
    @MainActor
    @discardableResult
    private func arrive(_ app: XCUIApplication) -> String {
        assertShown(app.element("im-here"))
        let before = waitForProbe(app, "a first reading") { _ in true }.auth
        XCTAssertNotEqual(
            before, "denied",
            "Notifications are denied for Dawri on this simulator. Uninstall the app and run again.")
        XCTAssertNotEqual(before, "none", "-demoNotify on did not give the real notifier")
        if before == "notDetermined" {
            // Nothing asks before the arrival moment.
            XCTAssertFalse(permissionAlert.waitForExistence(timeout: 3), "a prompt came before arrival")
        }
        app.element("im-here").tap()
        if before == "notDetermined" {
            XCTAssertTrue(permissionAlert.waitForExistence(timeout: 10), "no prompt at arrival")
            let allow = permissionAlert.buttons["Allow"]
            (allow.exists ? allow : permissionAlert.buttons.element(boundBy: 1)).tap()
        }
        assertShown(app.element("screen-ticket"))
        waitForProbe(app, "permission given") { $0.auth == "authorized" }
        return before
    }

    /// The ids the plan says should be pending: its notify steps not yet run, with time to go.
    /// `margin` leaves out a step so close to now that it may fire while the probe is read.
    private func expected(_ reading: LiveProbeReading, margin: Int = 3) -> (sure: Set<String>, allowed: Set<String>) {
        guard let visit = reading.followed else { return ([], []) }
        var sure: Set<String> = []
        var allowed: Set<String> = []
        for step in reading.plan {
            guard let offset = step.offset, LiveProbeReading.key(for: step) != nil else { continue }
            let id = "dawri.\(visit).\(step.index)"
            if offset > 0 { allowed.insert(id) }
            if offset > margin { sure.insert(id) }
        }
        return (sure, allowed)
    }

    @MainActor
    private func assertMatchesPlan(_ reading: LiveProbeReading, file: StaticString = #filePath, line: UInt = #line) {
        let ids = Set(reading.pending.map(\.id))
        let plan = expected(reading)
        XCTAssertFalse(plan.sure.isEmpty, "the plan has nothing ahead: \(reading.raw)", file: file, line: line)
        XCTAssertTrue(plan.sure.isSubset(of: ids), "missing: \(plan.sure.subtracting(ids)) in \(reading.raw)", file: file, line: line)
        XCTAssertTrue(ids.isSubset(of: plan.allowed), "not in the plan: \(ids.subtracting(plan.allowed)) in \(reading.raw)", file: file, line: line)
        // Each notice says what its step should, and they fire in plan order.
        let steps = Dictionary(uniqueKeysWithValues: reading.plan.map { ("dawri.\(reading.followed ?? "").\($0.index)", $0) })
        for notice in reading.pending {
            let step = steps[notice.id]
            XCTAssertEqual(notice.key, step.flatMap(LiveProbeReading.key(for:)), notice.id, file: file, line: line)
            // Due when its step is, as the plan stands now, so a moved plan was scheduled again.
            if let due = step?.offset, let fires = notice.offset {
                XCTAssertLessThanOrEqual(abs(due - fires), 1, "\(notice.id) in \(reading.raw)", file: file, line: line)
            }
        }
        let offsets = reading.pending.compactMap(\.offset)
        XCTAssertEqual(offsets.count, reading.pending.count, file: file, line: line)
        XCTAssertEqual(offsets, offsets.sorted(), file: file, line: line)
        XCTAssertEqual(Set(offsets).count, offsets.count, "two notices at one moment", file: file, line: line)
        XCTAssertTrue(offsets.allSatisfy { $0 > 0 }, file: file, line: line)
    }

    /// Permission is asked at the arrival moment and not before, and then the plan's notify
    /// steps are pending ahead of time, in order: the triage call, the move to the doctor, the
    /// doctor's call, the move to the pharmacy and its call.
    @MainActor
    func testPermissionIsAskedAtArrivalThenThePlanIsScheduledAhead() {
        let app = start(["-demoScreen", "s09", "-demoNotify", "on"])
        let before = arrive(app)
        print("NotificationTests: the permission before arrival was \(before)")
        let reading = waitForProbe(app, "the plan's notices pending") { reading in
            reading.followed != nil && !reading.plan.isEmpty
                && self.expected(reading).sure.isSubset(of: Set(reading.pending.map(\.id)))
        }
        assertMatchesPlan(reading)
        // The five of Fatima's visit, or the last of them if the clock has passed the first.
        let five = ["notify.next", "notify.stage", "notify.next", "notify.stage", "notify.next"]
        let keys = reading.pending.map(\.key)
        XCTAssertFalse(keys.isEmpty)
        XCTAssertEqual(Array(five.suffix(keys.count)), keys, reading.raw)
    }

    /// Demo: next step moves the plan, and the pending notices are scheduled again to match:
    /// the same ids for the steps still ahead, sooner, and the triage call gone once it has run.
    @MainActor
    func testDemoNextStepReschedulesThem() {
        let app = start(["-demoScreen", "s09", "-demoNotify", "on"])
        arrive(app)
        let first = waitForProbe(app, "the plan's notices pending") { reading in
            !reading.plan.isEmpty && self.expected(reading).sure.isSubset(of: Set(reading.pending.map(\.id)))
        }
        let firstIds = first.pending.map(\.id)

        tapDemoNextStep(app)
        // The step pulls the plan in by about 15 s, or runs the triage call and drops its notice.
        let moved = waitForProbe(app, "the notices scheduled again") { reading in
            let ids = reading.pending.map(\.id)
            guard !ids.isEmpty else { return false }
            return ids != firstIds
                || (reading.pending.first?.offset ?? 0) < (first.pending.first?.offset ?? 0) - 10
        }
        XCTAssertTrue(Set(moved.pending.map(\.id)).isSubset(of: Set(firstIds)), "a new id appeared: \(moved.raw)")
        assertMatchesPlan(moved)

        // On to the triage call: its notice is gone, the later ones stay.
        for _ in 0..<8 where !app.element("ticket-called").exists {
            tapDemoNextStep(app)
            sleep(1)
        }
        assertShown(app.element("ticket-called"))
        let called = waitForProbe(app, "the triage call's notice gone") { reading in
            guard let firstId = firstIds.first else { return false }
            return !reading.pending.isEmpty && !reading.pending.map(\.id).contains(firstId)
        }
        XCTAssertEqual(called.pending.first?.key, "notify.stage", called.raw)
        assertMatchesPlan(called)
    }

    /// Walked to the end, nothing of the visit is left pending.
    @MainActor
    func testNoneRemainAfterCompletion() {
        let app = start(["-demoScreen", "s09", "-demoNotify", "on"])
        arrive(app)
        waitForProbe(app, "notices pending") { !$0.pending.isEmpty }
        for _ in 0..<20 where !app.element("screen-complete").exists {
            if app.element("demo-next-step").exists, app.element("demo-next-step").isEnabled {
                app.element("demo-next-step").tap()
            }
            sleep(1)
        }
        assertShown(app.element("screen-complete"))
        waitForProbe(app, "nothing pending after completion") { $0.pending.isEmpty }
        holdProbe(app, for: 3, "nothing pending") { $0.pending.isEmpty }
    }

    /// Without `-demoNotify on` there is no notifier, so no prompt ever appears, through arrival
    /// and on, and nothing is pending.
    @MainActor
    func testWithoutTheFlagNoPromptEverAppears() {
        let app = start(["-demoScreen", "s09"])
        assertShown(app.element("im-here"))
        XCTAssertEqual(waitForProbe(app, "a first reading") { _ in true }.auth, "none")
        app.element("im-here").tap()
        assertShown(app.element("screen-ticket"))
        XCTAssertFalse(permissionAlert.waitForExistence(timeout: 5), "a prompt appeared without -demoNotify on")
        tapDemoNextStep(app)
        XCTAssertFalse(permissionAlert.waitForExistence(timeout: 3))
        let reading = probe(app)
        XCTAssertEqual(reading.auth, "none")
        XCTAssertTrue(reading.pending.isEmpty, reading.raw)
    }

    /// Opening the app is never the moment to ask: a launch straight onto a live ticket asks for
    /// nothing, whatever the permission is.
    @MainActor
    func testALaunchOntoATicketDoesNotAsk() {
        let app = start(["-demoScreen", "s10", "-demoNotify", "on"])
        assertShown(app.element("ticket-number"))
        waitForProbe(app, "a first reading") { $0.activities.count == 1 }
        XCTAssertFalse(permissionAlert.waitForExistence(timeout: 4), "a prompt came at launch")
    }
}
