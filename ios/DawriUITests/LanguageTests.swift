import XCTest

/// The language switch keeps the screen, and UIKit's navigation follows it. These read real
/// positions, because SwiftUI's own direction does not reach the bar or the swipe edge.
final class LanguageTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func assertBackIsOnThe(right: Bool, in app: XCUIApplication, _ context: String) {
        let back = app.backControl
        assertShown(back, context)
        let middle = app.frame.midX
        if right {
            XCTAssertGreaterThan(back.frame.midX, middle, "Back is not on the right. \(context)")
        } else {
            XCTAssertLessThan(back.frame.midX, middle, "Back is not on the left. \(context)")
        }
    }

    @MainActor
    func testArabicPushHasBackOnTheRightAndSwipesFromTheRightEdge() {
        let app = launch("-demoLang", "ar", "-demoScreen", "s01")
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"))
        assertBackIsOnThe(right: true, in: app, "arabic push")
        XCTAssertEqual(app.backControl.label, Copy.backAR)

        app.swipeBack(fromRightEdge: false)
        sleep(1)
        XCTAssertTrue(app.element("screen-login").exists, "Arabic popped from the left edge")

        app.swipeBack(fromRightEdge: true)
        assertShown(app.element("screen-welcome"), "swipe from the right edge")
    }

    @MainActor
    func testEnglishPushHasBackOnTheLeftAndSwipesFromTheLeftEdge() {
        let app = launch("-demoLang", "en", "-demoScreen", "s01")
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"))
        assertBackIsOnThe(right: false, in: app, "english push")
        XCTAssertEqual(app.backControl.label, Copy.backEN)

        app.swipeBack(fromRightEdge: true)
        sleep(1)
        XCTAssertTrue(app.element("screen-login").exists, "English popped from the right edge")

        app.swipeBack(fromRightEdge: false)
        assertShown(app.element("screen-welcome"), "swipe from the left edge")
    }

    /// Push in English, switch live, and the same screen is now Arabic with Arabic navigation.
    @MainActor
    func testLiveSwitchToArabicKeepsThePathAndMovesTheNavigation() {
        let app = launch("-demoLang", "en", "-demoScreen", "s01", "-demoControls", "1")
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"))
        XCTAssertEqual(app.element("footer").label, Copy.footerEN)
        assertShown(app.staticTexts[Copy.loginTitleEN])
        assertBackIsOnThe(right: false, in: app, "before the switch")

        app.element("language-toggle").tap()

        assertShown(app.staticTexts[Copy.loginTitleAR])
        assertShown(app.element("screen-login"), "the path was lost")
        XCTAssertEqual(app.element("debug-path").label, "login")
        XCTAssertEqual(app.element("footer").label, Copy.footerAR)
        XCTAssertEqual(app.element("footer-ai").label, Copy.aiAR)
        XCTAssertEqual(app.element("language-toggle").label, "English")
        XCTAssertEqual(app.backControl.label, Copy.backAR)
        assertBackIsOnThe(right: true, in: app, "after the switch")

        app.swipeBack(fromRightEdge: false)
        sleep(1)
        XCTAssertTrue(app.element("screen-login").exists, "the old edge still pops")

        app.swipeBack(fromRightEdge: true)
        assertShown(app.element("screen-welcome"), "swipe from the right edge after a live switch")
    }

    /// And the way back, including a new push after the switch.
    @MainActor
    func testLiveSwitchToEnglishAndAPushAfterIt() {
        let app = launch("-demoLang", "ar", "-demoScreen", "s01")
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"))
        assertBackIsOnThe(right: true, in: app, "before the switch")

        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.loginTitleEN])
        assertBackIsOnThe(right: false, in: app, "after the switch")
        app.swipeBack(fromRightEdge: true)
        sleep(1)
        XCTAssertTrue(app.element("screen-login").exists, "the old edge still pops")
        app.swipeBack(fromRightEdge: false)
        assertShown(app.element("screen-welcome"), "swipe from the left edge after a live switch")

        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.purposeAR])
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"))
        assertBackIsOnThe(right: true, in: app, "a push after two switches")
        app.swipeBack(fromRightEdge: true)
        assertShown(app.element("screen-welcome"), "swipe after two switches")
    }

    @MainActor
    func testTheToggleIsOnEveryScreenAndFollowsTheLanguage() {
        let app = launch("-demoLang", "ar", "-demoScreen", "s01")
        assertShown(app.element("language-toggle"))
        XCTAssertLessThan(app.element("language-toggle").frame.midX, app.frame.midX, "arabic")
        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.purposeEN])
        XCTAssertGreaterThan(app.element("language-toggle").frame.midX, app.frame.midX, "english")
    }

    /// A DEBUG launch can pick a language, and a screen reached by launch argument has the
    /// language's navigation from its first frame.
    @MainActor
    func testAScreenOpenedDirectlyStartsInTheRightDirection() {
        let app = launch("-demoLang", "ar", "-demoScreen", "s02")
        assertShown(app.element("screen-login"))
        assertBackIsOnThe(right: true, in: app, "direct launch")
    }
}
