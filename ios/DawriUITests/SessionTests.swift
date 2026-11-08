import XCTest

/// `AppModel`'s session and navigation rules, through the test controls until S02 and S03 exist.
final class SessionTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func assertLabel(
        _ id: String, _ expected: String, in app: XCUIApplication, file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let matches = NSPredicate(format: "label == %@", expected)
        let waited = expectation(for: matches, evaluatedWith: app.element(id))
        wait(for: [waited], timeout: 10)
        XCTAssertEqual(app.element(id).label, expected, file: file, line: line)
    }

    @MainActor
    private func calls(_ route: String, in app: XCUIApplication) -> Int {
        let pairs = app.element("debug-calls").label.split(separator: " ")
        let pair = pairs.first { $0.hasPrefix("\(route):") }
        return pair.flatMap { Int($0.dropFirst(route.count + 1)) } ?? 0
    }

    /// No language chosen, so Ravi's record decides, and the bars follow it. Logging out returns
    /// to Arabic with Back on the right, on S02 above Welcome.
    @MainActor
    func testTheRecordsLanguageMovesTheBarsAndLoggingOutMovesThemBack() {
        let app = launch("-demoScreen", "s02", "-demoControls", "1", "-demoSignIn", "DEMO-10003")
        assertShown(app.element("screen-login"))
        XCTAssertEqual(app.element("footer").label, Copy.footerAR)
        XCTAssertGreaterThan(app.backControl.frame.midX, app.frame.midX)

        app.element("debug-sign-in").tap()
        assertShown(app.element("screen-home"))
        assertLabel("debug-session", "en P003", in: app)
        assertLabel("debug-path", "", in: app)
        XCTAssertEqual(app.element("footer").label, Copy.footerEN)
        XCTAssertFalse(app.backControl.exists, "A second Home sits above the first")

        app.element("debug-push").tap()
        assertShown(app.backControl)
        XCTAssertLessThan(app.backControl.frame.midX, app.frame.midX, "Back is not on the left")

        app.element("debug-sign-out").tap()
        assertShown(app.element("screen-login"))
        assertLabel("debug-session", "ar -", in: app)
        assertLabel("debug-path", "login", in: app)
        XCTAssertEqual(app.element("footer").label, Copy.footerAR)
        assertShown(app.backControl)
        XCTAssertGreaterThan(app.backControl.frame.midX, app.frame.midX, "Back is not on the right")
        app.backControl.tap()
        assertShown(app.element("screen-welcome"))
    }

    /// A choice outranks the record, which is why a language launch argument counts as one.
    @MainActor
    func testAChosenLanguageOutranksTheRecord() {
        let app = launch(
            "-demoScreen", "s02", "-demoLang", "ar", "-demoControls", "1", "-demoSignIn", "DEMO-10003")
        assertShown(app.element("screen-login"))
        app.element("debug-sign-in").tap()
        assertShown(app.element("screen-home"))
        assertLabel("debug-session", "ar P003", in: app)
    }

    @MainActor
    func testA401FromTheSessionLoaderEndsTheSession() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "s03",
            "-demoFail", "getMe=unauthorized", "-demoControls", "1")
        assertShown(app.element("screen-login"))
        assertLabel("debug-path", "login", in: app)
        assertLabel("debug-session", "ar -", in: app)
    }

    @MainActor
    func testA401FromAVisitLoaderEndsTheSession() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "s10",
            "-demoFail", "getVisit=unauthorized", "-demoControls", "1")
        assertShown(app.element("screen-login"))
        assertLabel("debug-path", "login", in: app)
    }

    /// `footer.ai` stays up, and the read is tried again until it is answered.
    @MainActor
    func testHealthRetriesEveryTenSecondsWithTheAiLineUp() {
        let app = launch(
            "-demoLang", "en", "-demoScreen", "s01", "-demoFail", "health=network", "-demoControls", "1")
        assertShown(app.element("footer-ai"))
        let retried = NSPredicate { _, _ in self.calls("health", in: app) >= 2 }
        wait(for: [expectation(for: retried, evaluatedWith: app)], timeout: 14)
        XCTAssertEqual(app.element("footer-ai").label, Copy.aiEN)
    }

    /// A short screen still pulls, so `.refreshable` on a scaffold reaches its scroll.
    @MainActor
    func testPullToRefreshReachesTheScrollOfAShortScreen() {
        let app = launch("-demoLang", "en", "-demoScreen", "s03", "-demoControls", "1")
        assertShown(app.element("screen-home"))
        let loaded = NSPredicate { _, _ in self.calls("getMe", in: app) >= 1 }
        wait(for: [expectation(for: loaded, evaluatedWith: app)], timeout: 5)
        let before = calls("getMe", in: app)

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.1, thenDragTo: end)

        let pulled = NSPredicate { _, _ in self.calls("getMe", in: app) > before }
        wait(for: [expectation(for: pulled, evaluatedWith: app)], timeout: 5)
    }

    /// Pulls a screen down from a quarter to three quarters of its height, then waits for one more
    /// call of `route` than before the pull.
    @MainActor
    private func assertPullRefetches(_ route: String, _ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let loaded = NSPredicate { _, _ in self.calls(route, in: app) >= 1 }
        wait(for: [expectation(for: loaded, evaluatedWith: app)], timeout: 5)
        sleep(1)
        let before = calls(route, in: app)
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.75))
        start.press(forDuration: 0.1, thenDragTo: end)
        let pulled = NSPredicate { _, _ in self.calls(route, in: app) > before }
        let result = XCTWaiter().wait(for: [expectation(for: pulled, evaluatedWith: app)], timeout: 5)
        XCTAssertEqual(result, .completed, "a pull did not call \(route) again", file: file, line: line)
    }

    /// S10 pulls to read the visit again, as iOS Design section 8 says, on a frozen clock so
    /// nothing else reads it in the meantime.
    @MainActor
    func testPullToRefreshReadsTheTicketAgain() {
        let app = launch(
            "-demoLang", "en", "-demoScreen", "s10", "-demoPatient", "DEMO-10001", "-demoFreeze", "1",
            "-demoControls", "1")
        assertShown(app.element("screen-ticket"))
        assertPullRefetches("getVisit", app)
    }

    /// S12 pulls to read the history again.
    @MainActor
    func testPullToRefreshReadsTheHistoryAgain() {
        let app = launch(
            "-demoLang", "en", "-demoScreen", "s12", "-demoPatient", "DEMO-10002", "-demoHistory", "mixed",
            "-demoFreeze", "1", "-demoControls", "1")
        assertShown(app.element("screen-history"))
        assertPullRefetches("listVisits", app)
    }

    /// Each move starts the new gate from the last read, so its first frame is the screen.
    @MainActor
    func testAStageMoveShowsNoSkeleton() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "reserved",
            "-demoControls", "1")
        assertShown(app.element("screen-reserved"))
        let before = app.element("debug-skeletons").label
        app.element("debug-advance").tap()
        assertShown(app.element("screen-ticket"))
        for _ in 0..<3 { app.element("debug-advance").tap() }
        assertShown(app.element("screen-complete"))
        XCTAssertEqual(app.element("debug-skeletons").label, before)
    }

    /// A visit that is not an emergency cannot keep the cover, which has no back.
    @MainActor
    func testACoverOverAVisitThatIsNoEmergencyLeavesForTheCanonicalScreen() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "s06", "-demoStage", "triage",
            "-demoControls", "1")
        assertShown(app.element("screen-ticket"))
        XCTAssertFalse(app.element("screen-emergency").exists)
        XCTAssertTrue(app.element("debug-path").label.contains("ticket"))
        assertShown(app.backControl)
    }

    /// A demo reset under S06 goes to Home and says so.
    @MainActor
    func testAVisitGoneFromUnderTheCoverReturnsHome() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10003", "-demoScreen", "s06",
            "-demoFail", "getVisit=visit_not_found", "-demoControls", "1")
        assertShown(app.element("screen-home"))
        XCTAssertFalse(app.element("screen-emergency").exists)
        assertShown(app.staticTexts["The demo was reset, so that visit is gone."])
    }
}
