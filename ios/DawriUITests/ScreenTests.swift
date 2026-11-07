import XCTest

/// Every route is reachable by id, and each sits inside the scaffold: title, footer, AI line
/// and toggle, because those must exist on every patient screen.
final class ScreenTests: XCTestCase {
    private let screens: [(argument: String, identifier: String, title: String)] = [
        ("s02", "login", "Log in"),
        ("s03", "home", "Home"),
        ("s04", "who", "Who is this for?"),
        ("consent", "consent", "Before we start"),
        ("s05", "chat", "Reception"),
        ("s06", "emergency", "Emergency"),
        ("s07", "refill", "Medicine refill"),
        ("s08", "centre", "Choose a centre"),
        ("s09", "reserved", "Check-in"),
        ("s10", "ticket", "Your ticket"),
        ("s11", "complete", "Visit complete"),
        ("s12", "history", "History"),
        ("settings", "settings", "Settings"),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEveryScreenIsInTheScaffoldWithItsTitle() {
        for screen in screens {
            let app = launch("-demoLang", "en", "-demoScreen", screen.argument)
            assertShown(app.element("screen-\(screen.identifier)"), screen.argument)
            assertShown(app.staticTexts[screen.title], screen.argument)
            assertShown(app.element("language-toggle"), screen.argument)
            XCTAssertEqual(app.element("footer").label, Copy.footerEN, screen.argument)
            XCTAssertEqual(app.element("footer-ai").label, Copy.aiEN, screen.argument)
            app.terminate()
        }
    }

    /// A language switch must not move S01's anchors.
    @MainActor
    func testALanguageSwitchMovesNothingOnWelcome() {
        let app = launch("-demoLang", "en", "-demoScreen", "s01")
        assertShown(app.element("screen-welcome"))
        let login = app.element("welcome-login").frame
        let lockup = app.element("product-lockup").frame
        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.purposeAR])
        XCTAssertEqual(app.element("welcome-login").frame.minY, login.minY, accuracy: 0.5)
        XCTAssertEqual(app.element("product-lockup").frame.minY, lockup.minY, accuracy: 0.5)
    }
}
