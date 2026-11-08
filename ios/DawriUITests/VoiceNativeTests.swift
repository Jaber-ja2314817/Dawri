import XCTest

/// S05's voice on the phone's own recogniser where it is safe to run it, and on the scripted one
/// where it is not. **No test here records from the Mac's microphone:** the real
/// `SpeechVoiceEngine` runs only with the microphone refused, and every listening step uses
/// `-demoVoice`'s scripted recogniser, which hears nothing real.
final class VoiceNativeTests: XCTestCase {
    private let fatima = "DEMO-10001"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func chat(_ app: XCUIApplication, lang: String, _ extra: [String]) {
        app.launchArguments = ["-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "chat"] + extra
        app.launch()
        assertShown(app.element("screen-chat"), lang)
    }

    @MainActor
    private func bubbles(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: "bubble").count
    }

    @MainActor
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    /// The phone's own recogniser, with the microphone permission reset and then refused at the
    /// system prompt: S05 says the microphone is blocked, focuses the field, and typing sends as
    /// usual. Refusing is the only answer this test ever gives, so nothing is recorded.
    @MainActor
    func testTheRealRecogniserWithTheMicrophoneRefusedSaysDeniedAndTypingSends() {
        let app = XCUIApplication()
        app.resetAuthorizationStatus(for: .microphone)
        chat(app, lang: "en", ["-demoChat", "opening", "-demoVoice", "device"])

        app.element("chat-mic").tap()
        // The system prompt, if this run asks. Only ever refused.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let refuse = springboard.alerts.buttons["Don’t Allow"].firstMatch
        let refuseStraight = springboard.alerts.buttons["Don't Allow"].firstMatch
        if refuse.waitForExistence(timeout: 5) {
            refuse.tap()
        } else if refuseStraight.exists {
            refuseStraight.tap()
        }

        let line = app.element("voice-error")
        assertShown(line)
        XCTAssertEqual(line.label, "The microphone is blocked. Please type your message.")
        XCTAssertFalse(app.element("voice-listening").exists, "Nothing listens")
        XCTAssertFalse(springboard.alerts.firstMatch.exists, "No second prompt")

        let field = app.element("chat-input")
        let focused = NSPredicate(format: "hasKeyboardFocus == true")
        wait(for: [expectation(for: focused, evaluatedWith: field)], timeout: 5)
        let before = bubbles(app)
        field.typeText("I have a fever")
        XCTAssertFalse(line.exists, "Typing clears the voice line")
        app.element("chat-send").tap()
        XCTAssertTrue(waitUntil { self.bubbles(app) >= before + 2 }, "The typed line went and was answered")

        // A second tap on the mic asks nothing again and says the same.
        app.element("chat-mic").tap()
        assertShown(app.element("voice-error"))
        XCTAssertFalse(springboard.alerts.firstMatch.waitForExistence(timeout: 1))
    }

    /// The confirm step: the transcript waits in its field and nothing is sent until Send.
    @MainActor
    func testATranscriptIsNeverSentBeforeSend() {
        for lang in ["en", "ar"] {
            let app = XCUIApplication()
            chat(app, lang: lang, ["-demoChat", "midway", "-demoVoice", "confirm"])
            let transcript = app.element("voice-transcript")
            assertShown(transcript, lang)
            let words = transcript.value as? String ?? ""
            XCTAssertFalse(words.isEmpty, lang)
            let before = bubbles(app)

            // Time passes on the confirm step, and nothing goes.
            RunLoop.current.run(until: Date().addingTimeInterval(3))
            XCTAssertEqual(bubbles(app), before, "Nothing was sent before Send. \(lang)")
            XCTAssertFalse(app.element("chat-thinking").exists, lang)
            XCTAssertTrue(app.element("voice-confirm").exists, lang)

            app.element("voice-send").tap()
            XCTAssertTrue(waitUntil { self.bubbles(app) > before }, "Send sent it. \(lang)")
            XCTAssertTrue(
                app.descendants(matching: .any).matching(identifier: "bubble")
                    .containing(NSPredicate(format: "label CONTAINS %@", words)).count > 0
                    || app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", words)).count > 0,
                "The sent bubble is the transcript. \(lang)")
            XCTAssertFalse(app.element("voice-confirm").exists, lang)
            app.terminate()
        }
    }

    /// A language switch while listening restarts the recogniser in the new language: the
    /// scripted one hears its first words again, in Arabic, and is still listening.
    @MainActor
    func testALanguageSwitchWhileListeningRestartsInTheNewLanguage() {
        let app = XCUIApplication()
        chat(app, lang: "en", ["-demoChat", "midway", "-demoVoice", "listening"])
        let partial = app.element("voice-partial")
        assertShown(partial)
        XCTAssertEqual(partial.label, "I have a")
        let before = bubbles(app)

        app.element("language-toggle").firstMatch.tap()
        XCTAssertTrue(
            waitUntil { partial.exists && partial.label == "عندي حرارة وكحة" },
            "Listening again in Arabic, not \(partial.label)")
        XCTAssertTrue(app.element("voice-listening").exists)
        XCTAssertEqual(bubbles(app), before, "The switch sent nothing")

        app.element("language-toggle").firstMatch.tap()
        XCTAssertTrue(waitUntil { partial.exists && partial.label == "I have a" }, "And back in English")
        XCTAssertTrue(app.element("voice-listening").exists)
    }
}
