import XCTest

/// The canonical Dawri strings these tests expect, as the bundle has them. Written out here on
/// purpose: a test that read them from the app could not notice the wrong language.
enum Copy {
    static let footerEN = "Demo — synthetic data, not connected to PHCC/HMC systems."
    static let footerAR = "تجريبي — بيانات اصطناعية، غير متصل بأنظمة PHCC/HMC."
    static let aiEN = "AI: simulated"
    static let aiAR = "الذكاء الاصطناعي: محاكاة"
    static let purposeEN = "Check in for your health centre visit from your phone."
    static let purposeAR = "سجّل وصولك لزيارة المركز الصحي من هاتفك."
    static let loginEN = "Log in with Tawtheeq (demo)"
    static let loginAR = "تسجيل الدخول عبر توثيق (تجريبي)"
    static let loginTitleEN = "Log in"
    static let loginTitleAR = "تسجيل الدخول"
    static let backEN = "Back"
    static let backAR = "رجوع"
}

extension XCTestCase {
    @MainActor
    func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }
}

extension XCUIApplication {
    func element(_ identifier: String) -> XCUIElement {
        descendants(matching: .any)[identifier].firstMatch
    }

    /// The system back control, which keeps UIKit's identifier. The web's id is `back`.
    var backControl: XCUIElement {
        navigationBars.buttons["BackButton"].firstMatch
    }

    /// The left or right edge, drawn inward, with the finger starting on the very edge.
    func swipeBack(fromRightEdge: Bool) {
        let startX: CGFloat = fromRightEdge ? 0.995 : 0.005
        let endX: CGFloat = fromRightEdge ? 0.2 : 0.8
        let start = coordinate(withNormalizedOffset: CGVector(dx: startX, dy: 0.5))
        let end = coordinate(withNormalizedOffset: CGVector(dx: endX, dy: 0.5))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }
}

@MainActor
func assertShown(
    _ element: XCUIElement, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
) {
    XCTAssertTrue(
        element.waitForExistence(timeout: 10), "\(element) is not on screen. \(message)",
        file: file, line: line)
}
