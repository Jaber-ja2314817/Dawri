import XCTest

/// The mid-swipe wait in `AppModel.replace`. Fatima's ticket is staged at the pharmacy, called,
/// on the real clock, so the demo clinic's dispense step falls due about 15 seconds after launch
/// and moves the visit to S11. A swipe back is held across that moment. The stage move must wait
/// for the finger: a cancelled swipe then lands on S11 as a single entry, and a finished swipe
/// leaves Home with no S11 pushed over it. `debug-swipe-waits` counts the moves that waited, so
/// a move that landed before or after the hold cannot pass.
final class SwipeHoldTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func startAtThePharmacy() -> XCUIApplication {
        let app = launch(
            "-demoLang", "en", "-demoScreen", "s10", "-demoStage", "pharmacy", "-demoTicket", "called",
            "-demoControls", "1")
        assertShown(app.element("screen-ticket"))
        XCTAssertEqual(app.element("debug-swipe-waits").label, "0")
        return app
    }

    /// Holds a swipe from the left edge at `fraction` of the width for `seconds`, then lifts.
    @MainActor
    private func holdSwipe(_ app: XCUIApplication, to fraction: CGFloat, seconds: TimeInterval) {
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.005, dy: 0.5))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: fraction, dy: 0.5))
        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: seconds)
    }

    /// Let go short of halfway: the swipe cancels, and only then does S11 replace S10.
    @MainActor
    func testAStepDuringACancelledSwipeWaitsThenLands() {
        let app = startAtThePharmacy()
        holdSwipe(app, to: 0.3, seconds: 22)
        assertShown(app.element("screen-complete"), "S11 after the swipe ended")
        XCTAssertGreaterThanOrEqual(Int(app.element("debug-swipe-waits").label) ?? 0, 1, "the move did not wait")
        let path = app.element("debug-path").label
        XCTAssertEqual(path.components(separatedBy: " > ").count, 1, path)
        XCTAssertTrue(path.contains("complete"), path)
        app.backControl.tap()
        assertShown(app.element("screen-home"))
    }

    /// Let go past halfway: the swipe takes S10 away, so the move that waited finds no entry and
    /// pushes nothing.
    @MainActor
    func testAStepDuringAFinishedSwipeLeavesHome() {
        let app = startAtThePharmacy()
        holdSwipe(app, to: 0.85, seconds: 22)
        assertShown(app.element("screen-home"))
        XCTAssertGreaterThanOrEqual(Int(app.element("debug-swipe-waits").label) ?? 0, 1, "the move did not wait")
        sleep(2)
        XCTAssertFalse(app.element("screen-complete").exists, "S11 was pushed over Home")
        XCTAssertEqual(app.element("debug-path").label, "")
    }
}
