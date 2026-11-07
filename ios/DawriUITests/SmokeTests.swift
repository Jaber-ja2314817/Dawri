import XCTest

final class SmokeTests: XCTestCase {
    @MainActor
    func testRootViewExists() {
        let app = XCUIApplication()
        app.launch()

        let root = app.descendants(matching: .any)["app-root"]
        XCTAssertTrue(root.waitForExistence(timeout: 10), "The app's root view did not appear")
    }
}
