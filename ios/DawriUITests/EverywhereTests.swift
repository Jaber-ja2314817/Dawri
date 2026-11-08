import XCTest

/// Every screen and main state in ScreenTable, in both languages: the footer and the AI line in
/// the current language, the language toggle, and Back or none as iOS Design says. Then the
/// toggle: the path stays exactly as it was, the screen stays, and its title changes language.
/// One Back from every visit screen reaches Home. The chat draft and the login fields survive a
/// switch. `-demoControls 1` only reports the path here, it moves nothing.
final class EverywhereTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private struct Expected {
        let footer: String
        let ai: String
        /// The toggle names the other language in its own script.
        let toggle: String
    }

    private static func expected(_ lang: String) -> Expected {
        lang == "ar"
            ? Expected(footer: Copy.footerAR, ai: Copy.aiAR, toggle: "English")
            : Expected(footer: Copy.footerEN, ai: Copy.aiEN, toggle: "العربية")
    }

    /// S06 is a cover, and XCTest still lists the stack under it, so its checks look inside it.
    @MainActor
    private func scope(_ app: XCUIApplication, _ row: ScreenCase) -> XCUIElement {
        row.isCover ? app.element(row.screen) : app
    }

    @MainActor
    private func find(_ identifier: String, in app: XCUIApplication, _ row: ScreenCase) -> XCUIElement {
        scope(app, row).descendants(matching: .any)[identifier].firstMatch
    }

    /// The navigation bar's title, or S06's own heading.
    @MainActor
    private func title(_ app: XCUIApplication, _ row: ScreenCase, lang: String) -> String {
        if row.isCover {
            let heading = lang == "ar" ? Copy.emergencyTitleAR : Copy.emergencyTitleEN
            return scope(app, row).staticTexts[heading].exists ? heading : ""
        }
        return app.navigationBars.firstMatch.identifier
    }

    @MainActor
    private func check(_ app: XCUIApplication, _ row: ScreenCase, lang: String) {
        let context = "\(row.name) in \(lang)"
        let want = Self.expected(lang)
        let footer = find("footer", in: app, row)
        let ai = find("footer-ai", in: app, row)
        let toggle = find("language-toggle", in: app, row)
        let predicate = NSPredicate(format: "label == %@", want.footer)
        let landed = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: footer)], timeout: 10)
        XCTAssertEqual(landed, .completed, "\(context): footer reads '\(footer.label)'")
        XCTAssertEqual(ai.label, want.ai, "\(context): AI line")
        XCTAssertTrue(toggle.exists, "\(context): no language toggle")
        XCTAssertEqual(toggle.label, want.toggle, "\(context): toggle")
        switch row.back {
        case .none:
            XCTAssertFalse(app.backControl.exists, "\(context): a Back where there should be none")
        case .pushed, .home:
            XCTAssertTrue(app.backControl.exists, "\(context): no Back")
        }
    }

    @MainActor
    private func walk(startingIn lang: String) {
        let other = lang == "ar" ? "en" : "ar"
        for row in ScreenTable.all {
            let app = XCUIApplication()
            app.launchArguments = ["-demoLang", lang, "-demoControls", "1"] + row.arguments
            app.launch()
            guard app.element(row.screen).waitForExistence(timeout: 15) else {
                XCTFail("\(row.name): \(row.screen) never appeared")
                continue
            }
            sleep(1)
            check(app, row, lang: lang)
            let path = app.element("debug-path").label
            let before = title(app, row, lang: lang)
            XCTAssertFalse(before.isEmpty, "\(row.name) in \(lang): no title")

            find("language-toggle", in: app, row).tap()
            check(app, row, lang: other)
            XCTAssertTrue(app.element(row.screen).exists, "\(row.name): the switch left the screen")
            XCTAssertEqual(app.element("debug-path").label, path, "\(row.name): the switch moved the path")
            let after = title(app, row, lang: other)
            XCTAssertFalse(after.isEmpty, "\(row.name) in \(other): no title")
            XCTAssertNotEqual(after, before, "\(row.name): the title did not change language")

            if row.back == .home {
                app.backControl.tap()
                XCTAssertTrue(
                    app.element("screen-home").waitForExistence(timeout: 10), "\(row.name): one Back is not Home")
            }
            app.terminate()
        }
    }

    @MainActor
    func testEveryScreenFromEnglish() {
        walk(startingIn: "en")
    }

    @MainActor
    func testEveryScreenFromArabic() {
        walk(startingIn: "ar")
    }

    /// What the patient typed stays in the box through two switches.
    @MainActor
    func testTheChatDraftSurvivesASwitch() {
        let app = launch(
            "-demoLang", "en", "-demoScreen", "chat", "-demoPatient", "DEMO-10001", "-demoChat", "opening",
            "-demoFreeze", "1", "-demoControls", "1")
        let input = app.element("chat-input")
        assertShown(input)
        input.tap()
        input.typeText("fever since Monday")
        let path = app.element("debug-path").label
        app.element("language-toggle").tap()
        assertShown(app.buttons.matching(NSPredicate(format: "label == 'English'")).firstMatch, "the switch landed")
        XCTAssertEqual(app.element("chat-input").value as? String, "fever since Monday")
        app.element("language-toggle").tap()
        XCTAssertEqual(app.element("chat-input").value as? String, "fever since Monday")
        XCTAssertEqual(app.element("debug-path").label, path)
        XCTAssertTrue(app.element("screen-chat").exists)
    }

    /// The QID and the code stay in their fields through two switches.
    @MainActor
    func testTheLoginFieldsSurviveASwitch() {
        let app = launch("-demoLang", "ar", "-demoScreen", "s02", "-demoControls", "1")
        let qid = app.element("login-qid")
        assertShown(qid)
        qid.tap()
        qid.typeText("DEMO-10001")
        let otp = app.element("login-otp")
        otp.tap()
        otp.typeText("0000")
        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.loginTitleEN])
        XCTAssertEqual(app.element("login-qid").value as? String, "DEMO-10001")
        XCTAssertEqual(app.element("login-otp").value as? String, "0000")
        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.loginTitleAR])
        XCTAssertEqual(app.element("login-qid").value as? String, "DEMO-10001")
        XCTAssertEqual(app.element("login-otp").value as? String, "0000")
        XCTAssertTrue(app.element("screen-login").exists)
    }
}
