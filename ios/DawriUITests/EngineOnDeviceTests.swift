import XCTest

/// The rules and their resources work on iOS itself, not only under `swift test`. Each case
/// launches the real clinic and sends one real sentence, so the outcome comes from the bundled
/// rule tables. The screens are placeholders, so these assert on the route, the path and what
/// the service answered. Reading the status means a send that never ran cannot pass.
final class EngineOnDeviceTests: XCTestCase {
    private let ravi = "DEMO-10003"
    private let ahmed = "DEMO-10002"
    private let fatima = "DEMO-10001"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func send(_ text: String, as patient: String, lang: String) -> XCUIApplication {
        let app = launch(
            "-demoScreen", "chat", "-demoPatient", patient, "-demoControls", "1",
            "-demoLang", lang, "-demoSendText", text)
        assertShown(app.element("screen-chat"), text)
        app.element("debug-send-chat").tap()
        return app
    }

    @MainActor
    private func assertAnswer(_ answer: String, in app: XCUIApplication, _ context: String) {
        let predicate = NSPredicate(format: "label == %@", answer)
        let shown = expectation(for: predicate, evaluatedWith: app.element("debug-status"))
        wait(for: [shown], timeout: 10)
        XCTAssertEqual(app.element("debug-status").label, answer, context)
    }

    @MainActor
    private func assertEmergency(_ text: String, as patient: String, lang: String) {
        let app = send(text, as: patient, lang: lang)
        assertAnswer("redirected_emergency rules", in: app, text)
        assertShown(app.element("screen-emergency"), text)

        let path = app.element("debug-path").label
        XCTAssertTrue(path.contains("emergency"), path)
        XCTAssertFalse(path.contains("chat"), path)
        XCTAssertFalse(app.element("screen-chat").exists, text)
        XCTAssertFalse(app.backControl.exists, "The emergency screen has no back. \(text)")

        app.swipeBack(fromRightEdge: true)
        app.swipeBack(fromRightEdge: false)
        assertShown(app.element("screen-emergency"), text)
        XCTAssertFalse(app.element("screen-chat").exists, text)
        XCTAssertFalse(app.element("debug-path").label.contains("chat"), text)
    }

    @MainActor
    private func assertStaysInChat(_ text: String, as patient: String, lang: String) {
        let app = send(text, as: patient, lang: lang)
        assertAnswer("intake simulated", in: app, text)
        assertShown(app.element("screen-chat"), text)
        XCTAssertTrue(app.element("debug-path").label.contains("chat"), text)
        XCTAssertFalse(app.element("screen-emergency").exists, text)
    }

    @MainActor
    func testRaviInEnglishReachesEmergencyAndBackCannotReachChat() {
        assertEmergency("Chest pain spreading to my arm", as: ravi, lang: "en")
    }

    @MainActor
    func testRaviInArabicReachesEmergencyAndBackCannotReachChat() {
        assertEmergency("عندي ألم في الصدر ينتشر إلى ذراعي", as: ravi, lang: "ar")
    }

    @MainActor
    func testAhmedInArabicReachesTheRefillRoute() {
        let text = "أبي حبوب الضغط المعتادة"
        let app = send(text, as: ahmed, lang: "ar")
        assertAnswer("deflected_refill rules", in: app, text)
        assertShown(app.element("screen-refill"), text)
        let path = app.element("debug-path").label
        XCTAssertTrue(path.contains("refill"), path)
        XCTAssertFalse(path.contains("chat"), path)
    }

    @MainActor
    func testFatimaInArabicStaysInChat() {
        assertStaysInChat("عندي حرارة وكحة من ثلاث أيام", as: fatima, lang: "ar")
    }

    /// The rule reads the sentence and not the patient. Nothing but the real engine does this.
    @MainActor
    func testTheOutcomeFollowsTheSentenceNotThePatient() {
        assertEmergency("عندي ألم في الصدر ينتشر إلى ذراعي", as: fatima, lang: "ar")
        XCUIApplication().terminate()
        assertStaysInChat("I have a fever and cough for three days", as: ravi, lang: "en")
    }
}
