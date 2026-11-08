import CoreLocation
import XCTest

/// S08 and S09 on the phone's own frameworks. The location tests set the simulator's position with
/// `XCUIDevice.shared.location` and pass no `-demoLocation`, so the real `CoreLocationSource`
/// reads it, and the clinic decides the 150 m. The camera tests use the real `CameraDoorScanner`,
/// which the simulator has no camera for, and `-demoCamera`'s scripted reads.
final class ArrivalNativeTests: XCTestCase {
    private let fatima = "DEMO-10001"
    /// C-WAKRA in the clinic's seed.
    private let wakra = (lat: 25.17302, lng: 51.59575)

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func reserved(_ app: XCUIApplication, _ extra: [String] = []) {
        app.launchArguments = [
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09", "-demoFreeze", "1",
        ] + extra
        app.launch()
        assertShown(app.element("screen-reserved"))
    }

    @MainActor
    private func setLocation(lat: Double, lng: Double) {
        XCUIDevice.shared.location = XCUILocation(
            location: CLLocation(latitude: lat, longitude: lng))
    }

    /// Answers the system's location prompt, if this run shows one.
    @MainActor
    private func answerLocationPrompt(allow: Bool) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let alert = springboard.alerts.firstMatch
        guard alert.waitForExistence(timeout: 5) else { return }
        let labels = allow
            ? ["Allow While Using App", "Allow Once"]
            : ["Don’t Allow", "Don't Allow"]
        for label in labels where alert.buttons[label].exists {
            alert.buttons[label].tap()
            return
        }
        XCTFail("No \(labels) on the prompt: \(alert.buttons.allElementsBoundByIndex.map(\.label))")
    }

    @MainActor
    private func number(_ app: XCUIApplication) -> String {
        (app.element("ticket-number").value as? String) ?? app.element("ticket-number").label
    }

    // Location

    /// About 20 m from Al Wakra: Check with my location checks in, and S10 shows a number.
    @MainActor
    func testNearTheCentreCheckingWithMyLocationReachesTheTicket() {
        setLocation(lat: wakra.lat + 0.00018, lng: wakra.lng)
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        reserved(app)
        app.element("check-location").tap()
        answerLocationPrompt(allow: true)
        assertShown(app.element("screen-ticket"))
        assertShown(app.element("ticket-number"))
        XCTAssertNotNil(
            number(app).range(of: #"^T-\d{3}$"#, options: .regularExpression), number(app))
    }

    /// About 5 km away: the too-far notice with the distance in metres and the 150 m limit.
    @MainActor
    func testFiveKilometresAwayIsTooFarWithTheMetres() {
        setLocation(lat: wakra.lat + 0.045, lng: wakra.lng)
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        reserved(app)
        app.element("check-location").tap()
        answerLocationPrompt(allow: true)
        let notice = app.element("too-far")
        assertShown(notice)
        let metres = notice.label.range(of: #"You are (\d+) m from"#, options: .regularExpression)
            .map { String(notice.label[$0]).filter(\.isNumber) }
            .flatMap(Int.init)
        XCTAssertNotNil(metres, notice.label)
        XCTAssertTrue((4800...5200).contains(metres ?? 0), "About 5 km, \(notice.label)")
        XCTAssertTrue(notice.label.hasSuffix("check-in works within 150 m."), notice.label)
        XCTAssertTrue(app.element("screen-reserved").exists)
        XCTAssertFalse(app.element("ticket-number").exists)
    }

    /// Location refused at the prompt: the location-failed notice, and I'm here still works.
    @MainActor
    func testRefusedLocationIsLocationFailed() {
        setLocation(lat: wakra.lat + 0.00018, lng: wakra.lng)
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        reserved(app)
        app.element("check-location").tap()
        answerLocationPrompt(allow: false)
        assertShown(app.element("location-failed"))
        XCTAssertEqual(
            app.element("location-failed").label,
            "We could not read your location, so use I'm here instead.")
        XCTAssertFalse(app.element("screen-ticket").exists)

        // Refused stays refused: a second tap asks nothing and fails the same way.
        app.element("check-location").tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 2))
        assertShown(app.element("location-failed"))
        app.element("im-here").tap()
        assertShown(app.element("screen-ticket"))
    }

    /// S08's Use my location with a set position: the distances appear.
    @MainActor
    func testUseMyLocationOnTheMapShowsDistances() {
        setLocation(lat: wakra.lat + 0.00018, lng: wakra.lng)
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .location)
        app.launchArguments = [
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s08", "-demoFreeze", "1",
        ]
        app.launch()
        assertShown(app.element("screen-centre"))
        XCTAssertFalse(app.element("selected-distance").exists, "No distance before the tap")
        app.element("use-location").tap()
        answerLocationPrompt(allow: true)
        assertShown(app.element("selected-distance"))
        XCTAssertFalse(app.element("location-failed").exists)
    }

    // The door camera

    /// The simulator has no camera: the sheet shows the typed field only, with the line saying so.
    @MainActor
    func testWithNoCameraTheSheetShowsTheTypedFieldOnly() {
        let app = XCUIApplication()
        reserved(app)
        app.element("reserved-scan").tap()
        assertShown(app.textFields["door-code"])
        assertShown(app.element("door-camera-unavailable"))
        XCTAssertEqual(
            app.element("door-camera-unavailable").label,
            "The camera is not available. Type the code instead.")
        XCTAssertFalse(app.element("door-camera").exists)
        XCTAssertTrue(app.element("door-submit").exists)
    }

    /// The camera refused: the typed field only.
    @MainActor
    func testWithTheCameraDeniedTheSheetShowsTheTypedFieldOnly() {
        let app = XCUIApplication()
        reserved(app, ["-demoCamera", "denied"])
        app.element("reserved-scan").tap()
        assertShown(app.textFields["door-code"])
        assertShown(app.element("door-camera-unavailable"))
        XCTAssertFalse(app.element("door-camera").exists)
    }

    /// A scanned DOOR-C-WAKRA checks in the way a typed one does, and S10 shows the number.
    @MainActor
    func testAScannedDoorCodeReachesTheTicket() {
        let app = XCUIApplication()
        reserved(app, ["-demoCamera", "scan:DOOR-C-WAKRA"])
        // The scripted camera reads a second after it shows, which can be gone before a query
        // lands, so this test waits for the ticket. The link test below checks the preview.
        app.element("reserved-scan").tap()
        assertShown(app.element("screen-ticket"))
        assertShown(app.element("ticket-number"))
        XCTAssertEqual(number(app), "T-014")
        XCTAssertFalse(app.element("door-sheet").exists)
    }

    /// A scanned link is not a door code: nothing opens, nothing moves, nothing new shows, and the
    /// sheet keeps looking.
    @MainActor
    func testAScannedLinkOpensNothingAndStaysInTheSheet() {
        let app = XCUIApplication()
        reserved(app, ["-demoCamera", "scan:https://example.com"])
        app.element("reserved-scan").tap()
        assertShown(app.element("door-camera"))
        XCTAssertEqual(app.element("door-camera").label, "Camera, looking for the door code")
        XCTAssertTrue(app.textFields["door-code"].exists, "The typed field stays under the camera")
        XCTAssertLessThan(
            app.element("door-camera").frame.maxY, app.textFields["door-code"].frame.minY,
            "The preview sits above the typed field")
        RunLoop.current.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(app.state, .runningForeground, "Nothing opened outside the app")
        XCTAssertTrue(app.element("door-sheet").exists)
        XCTAssertTrue(app.element("door-camera").exists)
        XCTAssertFalse(app.element("door-code-error").exists)
        XCTAssertFalse(app.element("screen-ticket").exists)
        let typed = app.textFields["door-code"].value as? String ?? ""
        XCTAssertFalse(typed.localizedCaseInsensitiveContains("example"), "The link is not typed in: \(typed)")
    }
}
