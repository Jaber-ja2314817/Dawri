import XCTest

/// Every route is reachable by id, and each sits inside the scaffold: footer, AI line and toggle,
/// because those must exist on every patient screen. No titles here: real screens change them.
final class ScreenTests: XCTestCase {
    private let screens: [(argument: String, identifier: String)] = [
        ("s01", "welcome"),
        ("s02", "login"),
        ("s03", "home"),
        ("s04", "who"),
        ("consent", "consent"),
        ("s05", "chat"),
        ("s06", "emergency"),
        ("s07", "refill"),
        ("s08", "centre"),
        ("s09", "reserved"),
        ("s10", "ticket"),
        ("s11", "complete"),
        ("s12", "history"),
        ("settings", "settings"),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testEveryRouteIsInTheScaffold() {
        for (lang, footer, ai, toggle) in [
            ("en", Copy.footerEN, Copy.aiEN, "العربية"), ("ar", Copy.footerAR, Copy.aiAR, "English"),
        ] {
            for screen in screens {
                let context = "\(screen.argument) \(lang)"
                let app = launch("-demoLang", lang, "-demoScreen", screen.argument)
                assertShown(app.element("screen-\(screen.identifier)"), context)
                // On S06 the stack stays in the tree under the cover, so read the cover's own.
                let scope = screen.identifier == "emergency" ? app.element("screen-emergency") : app
                let any = scope.descendants(matching: .any)
                assertShown(any["language-toggle"].firstMatch, context)
                XCTAssertEqual(any["language-toggle"].firstMatch.label, toggle, context)
                XCTAssertEqual(any["footer"].firstMatch.label, footer, context)
                XCTAssertEqual(any["footer-ai"].firstMatch.label, ai, context)
                app.terminate()
            }
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
