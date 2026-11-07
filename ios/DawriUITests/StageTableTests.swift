import XCTest

/// Every row of frontend/src/lib/stages.test.ts, at the app level: ask for chat at each stage,
/// and the gate must land on that stage's canonical screen.
final class StageTableTests: XCTestCase {
    private struct Row {
        let stage: String
        let confirmed: Bool
        let screen: String
    }

    private let rows = [
        Row(stage: "intake", confirmed: false, screen: "chat"),
        Row(stage: "intake", confirmed: true, screen: "centre"),
        Row(stage: "emergency", confirmed: false, screen: "emergency"),
        Row(stage: "refill", confirmed: false, screen: "refill"),
        Row(stage: "reserved", confirmed: true, screen: "reserved"),
        Row(stage: "expired", confirmed: true, screen: "reserved"),
        Row(stage: "triage", confirmed: true, screen: "ticket"),
        Row(stage: "doctor", confirmed: true, screen: "ticket"),
        Row(stage: "pharmacy", confirmed: true, screen: "ticket"),
        Row(stage: "completed", confirmed: true, screen: "complete"),
        Row(stage: "cancelled", confirmed: false, screen: "home"),
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func check(_ row: Row, confirmed: Bool) {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "chat",
            "-demoStage", row.stage, "-demoConfirmed", confirmed ? "1" : "0")
        let context = "\(row.stage), confirmed \(confirmed)"
        assertShown(app.element("screen-\(row.screen)"), context)
        if row.screen != "chat" {
            XCTAssertFalse(app.element("screen-chat").exists, context)
        }
        app.terminate()
    }

    @MainActor
    func testEveryRowLandsOnItsCanonicalScreen() {
        for row in rows {
            check(row, confirmed: row.confirmed)
        }
    }

    /// `never offers chat`, confirmed or not, on every stage but an open intake.
    @MainActor
    func testChatAppearsOnlyForAnUnconfirmedIntake() {
        for row in rows where row.stage != "intake" {
            check(row, confirmed: !row.confirmed)
        }
    }

    @MainActor
    func testAVisitThatIsGoneReturnsHome() {
        let app = launch(
            "-demoLang", "en", "-demoPatient", "DEMO-10001", "-demoScreen", "chat",
            "-demoStage", "intake", "-demoControls", "1")
        assertShown(app.element("screen-chat"))
        app.element("debug-forget-visit").tap()
        assertShown(app.element("screen-home"))
        assertShown(app.staticTexts["The demo was reset, so that visit is gone."])
    }
}
