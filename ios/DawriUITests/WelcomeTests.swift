import XCTest

final class WelcomeTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testDefaultLaunchIsTheNormalWelcomeInArabic() {
        let app = launch()
        assertShown(app.element("screen-welcome"))
        XCTAssertEqual(app.element("welcome-login").label, Copy.loginAR)
        XCTAssertEqual(app.element("footer").label, Copy.footerAR)
    }

    @MainActor
    func testWelcomeInArabic() {
        let app = launch("-demoLang", "ar", "-demoScreen", "s01")
        assertShown(app.element("screen-welcome"))
        XCTAssertEqual(app.element("product-lockup").label, "دوري")
        XCTAssertEqual(app.element("welcome-purpose").label, Copy.purposeAR)
        XCTAssertEqual(app.element("welcome-login").label, Copy.loginAR)
        XCTAssertEqual(app.element("footer").label, Copy.footerAR)
        XCTAssertEqual(app.element("footer-ai").label, Copy.aiAR)
        XCTAssertEqual(app.element("language-toggle").label, "English")
    }

    @MainActor
    func testWelcomeInEnglish() {
        let app = launch("-demoLang", "en", "-demoScreen", "s01")
        assertShown(app.element("screen-welcome"))
        XCTAssertEqual(app.element("product-lockup").label, "Dawri")
        XCTAssertEqual(app.element("welcome-purpose").label, Copy.purposeEN)
        XCTAssertEqual(app.element("welcome-login").label, Copy.loginEN)
        XCTAssertEqual(app.element("footer").label, Copy.footerEN)
        XCTAssertEqual(app.element("footer-ai").label, Copy.aiEN)
        XCTAssertEqual(app.element("language-toggle").label, "العربية")
    }

    @MainActor
    func testEveryTargetIsAtLeast44Points() {
        let app = launch("-demoLang", "en", "-demoScreen", "s01")
        assertShown(app.element("screen-welcome"))
        for id in ["language-toggle", "settings-gear", "welcome-login"] {
            let frame = app.buttons[id].firstMatch.frame
            XCTAssertGreaterThanOrEqual(frame.width, 44, id)
            XCTAssertGreaterThanOrEqual(frame.height, 44, id)
        }
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"))
        let back = app.backControl.frame
        XCTAssertGreaterThanOrEqual(back.width, 44)
        XCTAssertGreaterThanOrEqual(back.height, 44)
    }

    /// AX3: everything is still there, and the action stays on the first screen.
    @MainActor
    func testAccessibilitySizeInBothLanguages() {
        for lang in ["ar", "en"] {
            let app = launch(
                "-demoLang", lang, "-demoScreen", "s01",
                "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL")
            assertShown(app.element("screen-welcome"))
            let screen = app.frame
            let login = app.element("welcome-login")
            XCTAssertTrue(login.isHittable, lang)
            XCTAssertLessThanOrEqual(login.frame.maxY, screen.maxY, lang)
            XCTAssertGreaterThan(app.element("footer").frame.height, 30, lang)
            app.terminate()
        }
    }
}
