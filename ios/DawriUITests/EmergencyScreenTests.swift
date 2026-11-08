import XCTest

/// S06, as a cover above the stack: the real send reaches it, nothing leaves it but the override
/// and `emergency.home`, and Call 999 needs nothing from anywhere.
final class EmergencyScreenTests: XCTestCase {
    private let ravi = "DEMO-10003"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func assertStatus(_ expected: String, in app: XCUIApplication, _ context: String = "") {
        let matches = NSPredicate(format: "label == %@", expected)
        let waited = expectation(for: matches, evaluatedWith: app.element("debug-status"))
        wait(for: [waited], timeout: 10)
        XCTAssertEqual(app.element("debug-status").label, expected, context)
    }

    /// UIKit keeps the stack in the window under a cover, and XCTest sees it there. The cover's
    /// own toggle is the one in the modal element.
    @MainActor
    private func coverToggle(in app: XCUIApplication) -> XCUIElement {
        app.element("screen-emergency").descendants(matching: .button)["language-toggle"].firstMatch
    }

    /// A staged S06, with no language argument passed twice.
    @MainActor
    private func staged(_ arguments: String..., lang: String = "en") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoLang", lang, "-demoPatient", ravi, "-demoScreen", "s06"] + arguments
        app.launch()
        return app
    }

    /// The sentence goes through the real rules, and the chat's entry is gone when S06 opens.
    @MainActor
    func testRaviReachesTheCoverFromARealSendInBothLanguages() {
        for (lang, title) in [("en", Copy.emergencyTitleEN), ("ar", Copy.emergencyTitleAR)] {
            let app = launch(
                "-demoLang", lang, "-demoPatient", ravi, "-demoScreen", "chat", "-demoStage", "intake",
                "-demoControls", "1")
            assertShown(app.element("screen-chat"), lang)
            app.element("debug-send-chat").tap()
            assertShown(app.element("screen-emergency"), lang)
            assertShown(app.staticTexts[title], lang)
            assertShown(app.element("emergency-call"), lang)

            let path = app.element("debug-path").label
            XCTAssertTrue(path.hasPrefix("emergency("), path)
            XCTAssertFalse(path.contains("chat"), path)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            XCTAssertFalse(app.backControl.exists, lang)

            app.swipeBack(fromRightEdge: true)
            app.swipeBack(fromRightEdge: false)
            app.swipeDown()
            sleep(1)
            assertShown(app.element("screen-emergency"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            XCTAssertTrue(app.element("emergency-call").isHittable, lang)
            app.terminate()
        }
    }

    /// The gate replacing chat with emergency goes to the cover too, with no entry left behind.
    @MainActor
    func testAGateThatLandsOnEmergencyOpensTheCover() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", ravi, "-demoScreen", "chat", "-demoStage", "emergency",
            "-demoControls", "1")
        assertShown(app.element("screen-emergency"))
        let path = app.element("debug-path").label
        XCTAssertTrue(path.hasPrefix("emergency("), path)
        XCTAssertFalse(path.contains(">"), path)
    }

    @MainActor
    func testCall999OpensTheDialerNumber() {
        let app = staged("-demoRecordLinks", "1")
        assertShown(app.element("emergency-call"))
        app.element("emergency-call").tap()
        assertStatus("opened tel://999", in: app)
    }

    @MainActor
    func testTheMapLinkOpensTheNearestDepartment() {
        let app = staged("-demoRecordLinks", "1")
        assertShown(app.element("emergency-nearest"))
        XCTAssertEqual(
            app.element("emergency-distance").label, "7 km from your registered centre")
        app.element("emergency-map").tap()
        assertStatus("opened maps://?ll=25.29349,51.50222", in: app)
    }

    @MainActor
    func testTheOverrideShowsTheRouteAndNoTicketThenGoesHome() {
        let app = staged("-demoControls", "1")
        assertShown(app.element("emergency-override"))
        app.element("emergency-override").tap()

        assertShown(app.element("emergency-route"))
        XCTAssertEqual(
            app.element("emergency-route").label,
            "Speak to a member of staff at the centre, or call 999")
        XCTAssertFalse(app.element("emergency-override").exists)
        XCTAssertFalse(app.element("ticket-number").exists)
        XCTAssertFalse(app.descendants(matching: .any)
            .matching(NSPredicate(format: "label MATCHES %@", "^[A-Z](-[A-Z]+)?-[0-9]{3}$")).firstMatch.exists)
        XCTAssertTrue(app.element("emergency-call").exists)

        app.element("emergency-home").tap()
        assertShown(app.element("screen-home"))
        XCTAssertFalse(app.element("screen-emergency").exists)
        XCTAssertEqual(app.element("debug-path").label, "")
    }

    /// The route follows the language too, and a failed override can be tried again.
    @MainActor
    func testAFailedOverrideRetries() {
        let app = staged("-demoFailOnce", "emergencyOverride=internal_error")
        app.element("emergency-override").tap()
        assertShown(app.element("emergency-error"))
        app.element("emergency-retry").tap()
        assertShown(app.element("emergency-route"))
        XCTAssertFalse(app.element("emergency-error").exists)
    }

    /// `not_emergency` reads the visit again, as the web does, and says so.
    @MainActor
    func testNotEmergencyRefetches() {
        let app = staged("-demoFail", "emergencyOverride=not_emergency", "-demoControls", "1")
        assertShown(app.element("emergency-override"))
        let before = app.element("debug-calls").label
        app.element("emergency-override").tap()
        assertShown(app.element("emergency-error"))
        XCTAssertNotEqual(app.element("debug-calls").label, before)
    }

    /// 999 does not wait for the visit, or depend on it.
    @MainActor
    func testARedFlagShowsTheTitleAndCallWhileTheVisitIsHeld() {
        for (lang, title) in [("en", Copy.emergencyTitleEN), ("ar", Copy.emergencyTitleAR)] {
            let app = staged("-demoRedFlag", "1", "-demoHold", "getVisit", "-demoRecordLinks", "1", lang: lang)
            assertShown(app.element("screen-emergency"), lang)
            assertShown(app.staticTexts[title], lang)
            assertShown(coverToggle(in: app), lang)
            assertShown(app.element("screen-emergency").descendants(matching: .any)["footer"], lang)
            XCTAssertFalse(app.element("emergency-reply").exists, lang)
            app.element("emergency-call").tap()
            assertStatus("opened tel://999", in: app, lang)
            app.terminate()
        }
    }

    @MainActor
    func testARedFlagWithAFailedLoadKeepsCallAndOffersRetry() {
        let app = staged("-demoRedFlag", "1", "-demoFail", "getVisit=network")
        assertShown(app.element("emergency-error"))
        assertShown(app.staticTexts[Copy.emergencyTitleEN])
        XCTAssertTrue(app.element("emergency-call").isHittable)
        XCTAssertFalse(app.element("emergency-home").exists, "A red flag has no way out but the override")
    }

    /// Arriving from a Home row, a failed load has what the web's Back gave it.
    @MainActor
    func testAFailedLoadFromARowCanStillLeave() {
        let app = staged("-demoFail", "getVisit=network", "-demoControls", "1")
        assertShown(app.element("emergency-error"))
        XCTAssertTrue(app.element("emergency-call").isHittable)
        app.element("emergency-home").tap()
        assertShown(app.element("screen-home"))
    }

    /// The real sentence through the real rules, then the screen's own text in the other language.
    @MainActor
    func testSelfHarmSaysSoInBothLanguages() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", ravi, "-demoScreen", "chat", "-demoStage", "intake",
            "-demoControls", "1", "-demoSendText", "I want to end my life")
        assertShown(app.element("screen-chat"))
        app.element("debug-send-chat").tap()
        assertShown(app.element("emergency-reply"))
        XCTAssertTrue(app.element("emergency-reply").label.contains(Copy.supportEN))
        coverToggle(in: app).tap()
        assertShown(app.staticTexts[Copy.emergencyTitleAR])
        XCTAssertTrue(app.element("emergency-reply").label.contains(Copy.supportAR))
    }

    @MainActor
    func testTheSelfHarmPatchShowsTheSameText() {
        let app = staged("-demoPatch", "selfHarm")
        assertShown(app.element("emergency-reply"))
        XCTAssertTrue(app.element("emergency-reply").label.contains(Copy.supportEN))
    }

    /// The cover is above the stack, so a switch re-renders it in place, and the override stays.
    @MainActor
    func testALanguageSwitchKeepsTheCover() {
        let app = staged("-demoControls", "1")
        assertShown(app.element("emergency-override"))
        app.element("emergency-override").tap()
        assertShown(app.element("emergency-route"))
        let path = app.element("debug-path").label

        coverToggle(in: app).tap()

        assertShown(app.staticTexts[Copy.emergencyTitleAR])
        assertShown(app.element("screen-emergency"))
        XCTAssertEqual(app.element("debug-path").label, path)
        let footer = app.element("screen-emergency").descendants(matching: .any)["footer"].firstMatch
        XCTAssertEqual(footer.label, Copy.footerAR)
        XCTAssertEqual(coverToggle(in: app).label, "English")
        XCTAssertEqual(
            app.element("emergency-route").label, "تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999")
        XCTAssertTrue(app.element("emergency-call").isHittable)
    }

    /// What the tree can prove: Call 999 comes first in the order XCTest reads the cover's
    /// elements, and the toggle and footer come last. It cannot prove what VoiceOver speaks, that
    /// its cursor lands there, or that it stays out of the stack under the cover. XCTest keeps
    /// showing that stack whatever the app does. Those need a real run with VoiceOver on.
    @MainActor
    func testCall999IsTheFirstElementInTheTree() {
        for lang in ["en", "ar"] {
            let app = staged(lang: lang)
            assertShown(app.element("emergency-override"), lang)
            let screen = app.element("screen-emergency")
            XCTAssertEqual(screen.elementType, .alert, "The cover is not modal. \(lang)")
            let order = screen.descendants(matching: .any).allElementsBoundByIndex
                .map(\.identifier).filter { !$0.isEmpty }
            XCTAssertEqual(order.first, "emergency-call", "\(lang): \(order)")
            let override = try? XCTUnwrap(order.firstIndex(of: "emergency-override"))
            let toggle = try? XCTUnwrap(order.firstIndex(of: "language-toggle"))
            let footer = try? XCTUnwrap(order.firstIndex(of: "footer"))
            XCTAssertLessThan(override ?? .max, toggle ?? .min, "\(lang): \(order)")
            XCTAssertLessThan(toggle ?? .max, footer ?? .min, "\(lang): \(order)")
            app.terminate()
        }
    }

    /// A pixel of the ground. The cover asks for the dark scheme, and that must stop at the cover.
    @MainActor
    private func assertGroundIsLight(in app: XCUIApplication, _ context: String) {
        sleep(1)
        let image = XCUIScreen.main.screenshot().image
        guard let data = image.cgImage?.dataProvider?.data, let bytes = CFDataGetBytePtr(data),
              let cg = image.cgImage
        else { return XCTFail("No screenshot") }
        let (x, y) = (cg.width / 2, cg.height / 2)
        let offset = y * cg.bytesPerRow + x * cg.bitsPerPixel / 8
        let bright = Int(bytes[offset]) + Int(bytes[offset + 1]) + Int(bytes[offset + 2])
        XCTAssertGreaterThan(bright, 700, "The app beneath turned dark. \(context)")
    }

    @MainActor
    func testTheAppBeneathStaysLight() {
        for theme in [["-demoTheme", "light"], []] {
            let app = XCUIApplication()
            app.launchArguments = ["-demoLang", "en", "-demoPatient", ravi, "-demoScreen", "s06",
                                   "-demoOverride", "1"] + theme
            app.launch()
            assertShown(app.element("emergency-home"), "\(theme)")
            app.element("emergency-home").tap()
            assertShown(app.element("screen-home"), "\(theme)")
            assertGroundIsLight(in: app, "\(theme)")
            app.terminate()
        }
    }
}
