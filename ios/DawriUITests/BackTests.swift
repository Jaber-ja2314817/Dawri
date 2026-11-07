import XCTest

/// Back and swipe-back can never return to a screen the visit has moved past.
final class BackTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    /// Ravi says something the chat cannot continue past. The chat's entry is replaced, so
    /// there is no way back to it, by button or by swipe from either edge.
    @MainActor
    func testBackCannotReachChatAfterAnEmergency() {
        for lang in ["en", "ar"] {
            let app = launch(
                "-demoLang", lang, "-demoPatient", "DEMO-10003", "-demoScreen", "chat",
                "-demoStage", "intake", "-demoControls", "1")
            assertShown(app.element("screen-chat"), lang)
            app.element("debug-send-chat").tap()
            assertShown(app.element("screen-emergency"), lang)

            XCTAssertFalse(app.element("screen-chat").exists, lang)
            XCTAssertFalse(app.backControl.exists, "The emergency screen has no back. \(lang)")
            XCTAssertFalse(app.element("debug-path").label.contains("chat"), lang)

            app.swipeBack(fromRightEdge: true)
            app.swipeBack(fromRightEdge: false)
            assertShown(app.element("screen-emergency"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            app.terminate()
        }
    }

    /// The same rule on a screen that does have Back: it goes Home, past the chat.
    @MainActor
    func testBackFromRefillGoesHomeNotToChat() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10002", "-demoScreen", "chat",
            "-demoStage", "intake", "-demoControls", "1")
        assertShown(app.element("screen-chat"))
        app.element("debug-send-chat").tap()
        assertShown(app.element("screen-refill"))
        XCTAssertFalse(app.element("debug-path").label.contains("chat"))
        app.backControl.tap()
        assertShown(app.element("screen-home"))
        XCTAssertFalse(app.element("screen-chat").exists)
    }

    /// Each stage move replaces the entry, so one Back from anywhere is Home.
    @MainActor
    func testAStageMoveLeavesASingleEntryAboveHome() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "reserved",
            "-demoControls", "1")
        assertShown(app.element("screen-reserved"))
        app.element("debug-advance").tap()
        assertShown(app.element("screen-ticket"))
        app.element("debug-advance").tap()
        app.element("debug-advance").tap()
        app.element("debug-advance").tap()
        assertShown(app.element("screen-complete"))
        XCTAssertEqual(app.element("debug-path").label.components(separatedBy: " > ").count, 1)
        app.backControl.tap()
        assertShown(app.element("screen-home"))
    }
}
