import XCTest

/// S05 and S07 through real taps on the real clinic: typed turns to the summary, Yes, Change, the
/// unsent hold, a retry, the refill route, a language switch mid-chat and a red flag mid-turn.
///
/// No `-demoControls` here: its bar sits over the composer, so every step is the patient's own
/// tap, and the path is proved by where one Back lands.
final class ChatScreenTests: XCTestCase {
    private let fatima = "DEMO-10001"
    private let ahmed = "DEMO-10002"
    private let ravi = "DEMO-10003"

    /// The demo's own answers, as a patient would type them.
    private let answers = [
        "ar": ["عندي حرارة وكحة من ثلاث أيام", "6", "بنادول", "لا"],
        "en": ["I have a fever and cough for three days", "6", "panadol", "no"],
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func chat(_ patient: String, lang: String, _ extra: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoLang", lang, "-demoPatient", patient, "-demoScreen", "chat"]
            + extra
        app.launch()
        assertShown(app.element("screen-chat"), lang)
        return app
    }

    @MainActor
    private func bubbles(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: "bubble").count
    }

    /// Types into the box and taps Send, the patient's way.
    @MainActor
    private func send(_ text: String, in app: XCUIApplication) {
        let field = app.element("chat-input")
        assertShown(field, text)
        if !(field.value(forKey: "hasKeyboardFocus") as? Bool ?? false) { field.tap() }
        field.typeText(text)
        XCTAssertEqual(field.value as? String, text, "The box did not take the words")
        app.element("chat-send").tap()
    }

    /// The reply has landed and the box takes words again.
    @MainActor
    private func waitForReply(after count: Int, in app: XCUIApplication, _ context: String = "") {
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if bubbles(app) > count + 1 || app.element("chat-summary").exists,
               !app.element("chat-thinking").exists {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        XCTFail("No reply after \(count) bubbles. \(context)")
    }

    /// Fatima answers until the read-back, typing each line.
    @MainActor
    private func typeToSummary(_ app: XCUIApplication, lang: String) {
        let lines = answers[lang]! + Array(repeating: answers[lang]!.last!, count: 4)
        for line in lines {
            if app.element("chat-summary").exists { return }
            let before = bubbles(app)
            send(line, in: app)
            waitForReply(after: before, in: app, line)
        }
        assertShown(app.element("chat-summary"), lang)
    }

    @MainActor
    func testFatimaTypesToTheSummaryAndYesReachesTheCentreInBothLanguages() {
        for lang in ["ar", "en"] {
            let app = chat(fatima, lang: lang, "-demoChat", "opening")
            typeToSummary(app, lang: lang)
            let check = lang == "ar" ? "هل هذا صحيح؟" : "Is this right?"
            assertShown(app.staticTexts[check], lang)
            XCTAssertFalse(app.element("chat-summary-text").label.hasSuffix(check), lang)
            XCTAssertTrue(app.element("chat-summary-yes").isEnabled, lang)

            app.element("chat-summary-yes").tap()
            assertShown(app.element("screen-centre"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            // The chat's entry was replaced: one Back is Home.
            app.backControl.tap()
            assertShown(app.element("screen-home"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            app.terminate()
        }
    }

    @MainActor
    func testChangeFocusesTheField() {
        let app = chat(fatima, lang: "en", "-demoChat", "summary")
        assertShown(app.element("chat-summary-change"))
        XCTAssertFalse(app.element("chat-input").value(forKey: "hasKeyboardFocus") as? Bool ?? true)
        app.element("chat-summary-change").tap()
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        wait(for: [expectation(for: focused, evaluatedWith: app.element("chat-input"))], timeout: 5)
        assertShown(app.keyboards.firstMatch)
    }

    @MainActor
    func testUnsentWordsDisableYesUntilTheBoxIsEmpty() {
        let app = chat(fatima, lang: "en", "-demoChat", "summary")
        let yes = app.element("chat-summary-yes")
        assertShown(yes)
        XCTAssertTrue(yes.isEnabled)
        XCTAssertFalse(app.element("chat-summary-unsent").exists)

        let field = app.element("chat-input")
        field.tap()
        field.typeText("chest pain")
        assertShown(app.element("chat-summary-unsent"))
        XCTAssertEqual(app.element("chat-summary-unsent").label, "Send or clear your message first.")
        XCTAssertFalse(yes.isEnabled)
        yes.tap()
        sleep(1)
        XCTAssertTrue(app.element("chat-summary").exists, "Yes went through with words unsent")
        XCTAssertFalse(app.element("screen-centre").exists)

        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 10))
        let enabled = NSPredicate(format: "isEnabled == true")
        wait(for: [expectation(for: enabled, evaluatedWith: yes)], timeout: 5)
        XCTAssertFalse(app.element("chat-summary-unsent").exists)
    }

    @MainActor
    func testATranscriptWaitingToBeSentDisablesYes() {
        let app = chat(fatima, lang: "en", "-demoChat", "summary", "-demoVoice", "confirm")
        assertShown(app.element("voice-transcript"))
        XCTAssertFalse(app.element("chat-summary-yes").isEnabled)
        assertShown(app.element("chat-summary-unsent"))
        app.element("voice-clear").tap()
        let before = bubbles(app)
        let enabled = NSPredicate(format: "isEnabled == true")
        wait(for: [expectation(for: enabled, evaluatedWith: app.element("chat-summary-yes"))], timeout: 5)
        XCTAssertFalse(app.element("chat-summary-unsent").exists)
        XCTAssertEqual(bubbles(app), before, "Clear sent nothing")
    }

    @MainActor
    func testRetryAfterAFailedSendKeepsTheWordsAndSendsOnce() {
        let app = chat(fatima, lang: "en", "-demoChat", "opening", "-demoFailOnce", "sendChat=network")
        let before = bubbles(app)
        send("I have a fever and cough for three days", in: app)
        assertShown(app.element("chat-error"))
        XCTAssertEqual(app.element("chat-input").value as? String, "I have a fever and cough for three days")
        XCTAssertEqual(bubbles(app), before)

        app.element("chat-error").buttons["Retry"].tap()
        waitForReply(after: before, in: app)
        XCTAssertFalse(app.element("chat-error").exists)
        // One message and one reply: the words were stored once, not twice.
        sleep(1)
        XCTAssertEqual(bubbles(app), before + 2)
        XCTAssertEqual(app.element("chat-input").value as? String ?? "", "")
    }

    @MainActor
    func testAhmedReachesRefillWithNoTicketAndBackGoesHome() {
        for lang in ["en", "ar"] {
            let text = lang == "ar" ? "أبي حبوب الضغط المعتادة" : "I need my usual blood pressure tablets."
            let app = chat(ahmed, lang: lang, "-demoChat", "opening")
            send(text, in: app)
            assertShown(app.element("screen-refill"), lang)
            let medicine = lang == "ar" ? "أملوديبين" : "amlodipine"
            XCTAssertTrue(app.element("refill-medicine").label.contains(medicine), app.element("refill-medicine").label)
            XCTAssertFalse(app.element("ticket-number").exists, lang)
            XCTAssertFalse(app.descendants(matching: .any)
                .matching(NSPredicate(format: "label MATCHES %@", "^[A-Z](-[A-Z]+)?-[0-9]{3}$")).firstMatch.exists)
            app.element("refill-message").tap()
            assertShown(app.element("refill-notice"), lang)

            app.backControl.tap()
            assertShown(app.element("screen-home"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            app.terminate()
        }
    }

    @MainActor
    func testIStillWantAVisitReachesTheCentre() {
        let app = XCUIApplication()
        app.launchArguments = ["-demoLang", "en", "-demoPatient", ahmed, "-demoScreen", "s07"]
        app.launch()
        assertShown(app.element("refill-visit"))
        app.element("refill-visit").tap()
        assertShown(app.element("screen-centre"))
        app.backControl.tap()
        assertShown(app.element("screen-home"))
    }

    @MainActor
    func testALanguageSwitchKeepsTheDraftTheTranscriptAndThePath() {
        let app = chat(fatima, lang: "en", "-demoChat", "midway")
        let field = app.element("chat-input")
        field.tap()
        field.typeText("half a sentence")
        let before = bubbles(app)
        app.element("language-toggle").firstMatch.tap()
        assertShown(app.staticTexts["الاستقبال"])
        XCTAssertEqual(app.element("chat-input").value as? String, "half a sentence")
        // The same screen and conversation, and one Back still reaches Home.
        XCTAssertTrue(app.element("screen-chat").exists)
        XCTAssertEqual(bubbles(app), before)
        app.backControl.tap()
        assertShown(app.element("screen-home"))
        app.terminate()

        let heard = chat(fatima, lang: "en", "-demoChat", "midway", "-demoVoice", "confirm")
        assertShown(heard.element("voice-transcript"))
        let words = heard.element("voice-transcript").value as? String
        let shown = bubbles(heard)
        heard.element("language-toggle").firstMatch.tap()
        assertShown(heard.staticTexts["الاستقبال"])
        XCTAssertEqual(heard.element("voice-transcript").value as? String, words)
        XCTAssertEqual(bubbles(heard), shown, "The switch sent nothing")
    }

    @MainActor
    func testARedFlagDuringATurnOpensTheCover() {
        for lang in ["en", "ar"] {
            let text = lang == "ar" ? "عندي ألم في الصدر ينتشر إلى ذراعي" : "Chest pain going to my left arm."
            let app = chat(ravi, lang: lang, "-demoChat", "opening")
            send(text, in: app)
            assertShown(app.element("screen-emergency"), lang)
            assertShown(app.element("emergency-call"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            XCTAssertFalse(app.backControl.exists, lang)
            app.swipeBack(fromRightEdge: lang == "ar")
            assertShown(app.element("screen-emergency"), lang)
            XCTAssertFalse(app.element("screen-chat").exists, lang)
            app.terminate()
        }
    }

    /// The build's own recogniser reports itself unavailable: the line shows, the field takes
    /// focus, and typing still works. Nothing is sent to a server.
    @MainActor
    func testVoiceUnavailableSaysSoAndTypingStillWorks() {
        let app = chat(fatima, lang: "en", "-demoChat", "opening")
        app.element("chat-mic").tap()
        assertShown(app.element("voice-error"))
        XCTAssertEqual(
            app.element("voice-error").label,
            "Voice is not available on this phone. Please type your message.")
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        wait(for: [expectation(for: focused, evaluatedWith: app.element("chat-input"))], timeout: 5)
        let before = bubbles(app)
        app.element("chat-input").typeText("I have a fever")
        XCTAssertFalse(app.element("voice-error").exists, "Typing clears the voice line")
        app.element("chat-send").tap()
        waitForReply(after: before, in: app)
    }
}
