import XCTest

/// `PatientScaffold`'s slots, and the launch hooks wave 2's screens stand on, read through the
/// proxy with `debug-read`, so each one is proven to reach the screens' side of the protocol.
final class FoundationHookTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// One `key=value` pair of `debug-read`.
    private func reading(_ status: String) -> [String: String] {
        var values: [String: String] = [:]
        for pair in status.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { values[parts[0]] = parts[1] }
        }
        return values
    }

    @MainActor
    private func read(_ arguments: [String]) -> [String: String] {
        let app = XCUIApplication()
        app.launchArguments = ["-demoLang", "en", "-demoControls", "1"] + arguments
        app.launch()
        assertShown(app.element("debug-read"), "\(arguments)")
        app.element("debug-read").tap()
        let done = NSPredicate(format: "label BEGINSWITH 'stage=' OR label BEGINSWITH 'failed'")
        wait(for: [expectation(for: done, evaluatedWith: app.element("debug-status"))], timeout: 10)
        let status = app.element("debug-status").label
        app.terminate()
        XCTAssertTrue(status.hasPrefix("stage="), "\(arguments): \(status)")
        return reading(status)
    }

    // Slots

    @MainActor
    func testThePinnedFooterLeavesWhileTheKeyboardIsUp() {
        let app = launch("-demoLang", "en", "-demoScreen", "gallery", "-demoPage", "10")
        assertShown(app.element("footer"))
        XCTAssertTrue(app.element("footer").isHittable)
        app.textFields.firstMatch.tap()
        let gone = NSPredicate(format: "exists == false")
        wait(for: [expectation(for: gone, evaluatedWith: app.element("footer"))], timeout: 5)
        app.typeText("\n")
        assertShown(app.element("footer"), "the footer did not return")
    }

    @MainActor
    func testThePinnedSlotsStayAndTheScrollPositionMoves() {
        let app = launch("-demoLang", "en", "-demoScreen", "gallery", "-demoPage", "10")
        assertShown(app.element("slots-top"))
        let top = app.element("slots-top").frame
        let bottom = app.element("slots-bottom").frame
        XCTAssertFalse(app.element("slots-row-29").isHittable)
        app.element("slots-top").tap()
        let reached = NSPredicate(format: "isHittable == true")
        wait(for: [expectation(for: reached, evaluatedWith: app.element("slots-row-29"))], timeout: 5)
        XCTAssertEqual(app.element("slots-top").frame, top)
        XCTAssertEqual(app.element("slots-bottom").frame, bottom)
        XCTAssertLessThan(top.maxY, app.element("slots-bottom").frame.minY)
    }

    // Staging

    @MainActor
    func testTheTicketWalks() {
        let base = ["-demoScreen", "s10", "-demoPatient", "DEMO-10001"]
        XCTAssertEqual(read(base + ["-demoTicket", "called"])["state"], "called")
        XCTAssertEqual(read(base + ["-demoTicket", "serving"])["state"], "serving")
    }

    @MainActor
    func testTheChatWalks() {
        let base = ["-demoScreen", "chat", "-demoPatient", "DEMO-10001"]
        XCTAssertEqual(read(base + ["-demoChat", "opening"])["user"], "0")
        XCTAssertEqual(read(base + ["-demoChat", "midway"])["user"], "2")
        let summary = read(base + ["-demoChat", "summary"])
        XCTAssertEqual(summary["intake"], "true")
        XCTAssertEqual(summary["stage"], "intake")
    }

    @MainActor
    func testExpiresInLeavesThatMuchTime() throws {
        let values = read(["-demoScreen", "s09", "-demoPatient", "DEMO-10001", "-demoExpiresIn", "600"])
        let left = try XCTUnwrap(values["left"].flatMap(Int.init))
        XCTAssertTrue((570...600).contains(left), "\(left)")
        XCTAssertEqual(values["stage"], "reserved")
    }

    @MainActor
    func testADependentsVisit() {
        let values = read(["-demoScreen", "s10", "-demoPatient", "DEMO-10001", "-demoFor", "P004"])
        XCTAssertEqual(values["patient"], "P004")
    }

    @MainActor
    func testAMixedHistory() {
        XCTAssertEqual(
            read(["-demoScreen", "s12", "-demoPatient", "DEMO-10002", "-demoHistory", "mixed"])["rows"],
            "completed+emergency+expired+refill")
        XCTAssertEqual(
            read(["-demoScreen", "s12", "-demoPatient", "DEMO-10001", "-demoHistory", "mixed"])["rows"],
            "completed+emergency+expired")
    }

    /// Past the demo clinic's 15 second step, the frozen clock has moved nothing.
    @MainActor
    func testFreezeHoldsTheClinicStill() {
        let app = launch(
            "-demoLang", "en", "-demoControls", "1", "-demoScreen", "s10", "-demoPatient", "DEMO-10001",
            "-demoFreeze", "1")
        assertShown(app.element("debug-read"))
        app.element("debug-read").tap()
        let done = NSPredicate(format: "label BEGINSWITH 'stage='")
        wait(for: [expectation(for: done, evaluatedWith: app.element("debug-status"))], timeout: 10)
        let before = reading(app.element("debug-status").label)
        sleep(20)
        app.element("debug-read").tap()
        sleep(1)
        let after = reading(app.element("debug-status").label)
        XCTAssertEqual(after["state"], before["state"])
        XCTAssertEqual(after["ahead"], before["ahead"])
        XCTAssertEqual(after["number"], before["number"])
    }

    // Patches

    @MainActor
    func testThePatchesOnAVisit() {
        let ticket = ["-demoScreen", "s10", "-demoPatient", "DEMO-10001"]
        XCTAssertEqual(read(ticket + ["-demoPatch", "noTicket"])["number"], "nil")
        let zero = read(ticket + ["-demoPatch", "zeroAhead"])
        XCTAssertEqual(zero["ahead"], "0")
        XCTAssertEqual(zero["wait"], "0")
        XCTAssertEqual(zero["centreWait"], "0")
        let unknown = read(ticket + ["-demoPatch", "unknownFigures"])
        XCTAssertEqual(unknown["ahead"], "nil")
        XCTAssertEqual(unknown["wait"], "nil")
        XCTAssertEqual(unknown["centreWait"], "nil")

        XCTAssertNotEqual(read(["-demoScreen", "s11", "-demoPatient", "DEMO-10001"])["meds"], "0")
        XCTAssertEqual(
            read(["-demoScreen", "s11", "-demoPatient", "DEMO-10001", "-demoPatch", "noMedicines"])["meds"], "0")
        XCTAssertNotEqual(read(["-demoScreen", "s07", "-demoPatient", "DEMO-10002"])["refill"], "nil")
        XCTAssertEqual(
            read(["-demoScreen", "s07", "-demoPatient", "DEMO-10002", "-demoPatch", "noRefillMedicine"])["refill"], "nil")
        XCTAssertEqual(
            read(["-demoScreen", "s06", "-demoPatient", "DEMO-10003", "-demoPatch", "selfHarm"])["harm"], "true")
    }

    @MainActor
    func testThePatchesOnTheCentreList() {
        let base = ["-demoScreen", "s08", "-demoPatient", "DEMO-10001"]
        let none = read(base + ["-demoPatch", "noCentres"])
        XCTAssertEqual(none["centres"], "0")
        XCTAssertEqual(none["default"], "nil")
        XCTAssertEqual(read(base + ["-demoPatch", "gpFirst"])["fallback"], "true")
        XCTAssertNotEqual(read(base + ["-demoPatch", "suggestion"])["suggestion"], "nil")
        let unchosen = read(base + ["-demoPatch", "noDefaultCentre"])
        XCTAssertEqual(unchosen["default"], "nil")
        XCTAssertNotEqual(unchosen["centres"], "0")
    }

    @MainActor
    func testADriverOnlyWhenTheClinicHasOne() {
        let base = ["-demoScreen", "s10", "-demoPatient", "DEMO-10001"]
        XCTAssertEqual(read(base)["driver"], "true")
        XCTAssertEqual(read(base + ["-demoNoDriver", "1"])["driver"], "false")
    }

    // Faults

    @MainActor
    func testAFailureCarriesItsDetail() {
        let app = launch(
            "-demoLang", "en", "-demoControls", "1", "-demoScreen", "s10", "-demoPatient", "DEMO-10001",
            "-demoFail", "listCentres=too_far:400")
        assertShown(app.element("debug-read"))
        app.element("debug-read").tap()
        let failed = NSPredicate(format: "label == 'failed too_far'")
        wait(for: [expectation(for: failed, evaluatedWith: app.element("debug-status"))], timeout: 10)
    }

    /// On `listCentres`, which only the test control calls on S10. Home, the stack root under S10,
    /// reads `listVisits` when it appears, which could use up a one-time failure first.
    @MainActor
    func testFailOnceFailsOnce() {
        let app = launch(
            "-demoLang", "en", "-demoControls", "1", "-demoScreen", "s10", "-demoPatient", "DEMO-10001",
            "-demoFailOnce", "listCentres=network")
        assertShown(app.element("debug-read"))
        app.element("debug-read").tap()
        let failed = NSPredicate(format: "label == 'failed network'")
        wait(for: [expectation(for: failed, evaluatedWith: app.element("debug-status"))], timeout: 10)
        app.element("debug-read").tap()
        let worked = NSPredicate(format: "label BEGINSWITH 'stage='")
        wait(for: [expectation(for: worked, evaluatedWith: app.element("debug-status"))], timeout: 10)
    }

    /// The first read held, and the screen is still loading, with the stream open behind it.
    @MainActor
    func testHoldNeverAnswers() {
        let app = launch(
            "-demoLang", "en", "-demoControls", "1", "-demoScreen", "s10", "-demoPatient", "DEMO-10001",
            "-demoHold", "getVisit")
        assertShown(app.element("visit-loading"))
        XCTAssertEqual(app.element("visit-loading").label, "Loading")
        sleep(2)
        XCTAssertTrue(app.element("visit-loading").exists)
        XCTAssertFalse(app.element("screen-ticket").exists)
    }
}
