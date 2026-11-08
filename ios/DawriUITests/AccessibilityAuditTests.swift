import XCTest

/// `performAccessibilityAudit` for dynamic type, contrast, hit regions, clipped text and element
/// detection, on every screen and main state in ScreenTable, in Arabic and English, plus the
/// door-code sheet. Each accepted finding is in `exclusions`, with its reason.
final class AccessibilityAuditTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = true
    }

    private let exclusions: [AuditExclusion] = [
        AuditExclusion(
            type: .dynamicType, labels: ["Dawri", "دوري"], above: 110,
            reason: """
                The product name in the navigation bar. The system bar holds what it carries to its \
                own height, as iOS Design section 2 says of `.barTitle`, and a long press shows it in \
                the large content viewer.
                """),
        AuditExclusion(
            type: .contrast, above: 200,
            reason: """
                Text in the top 200 pt sits under the system navigation bar or its soft scroll edge \
                effect, which iOS Design section 5 leaves to the system. The audit then measures our \
                text against the system's material. On a resting screen the effect only darkens the \
                ground a step: the Demo data pill measured 9.42:1 from the screenshot's own pixels, \
                and its tokens pass DesignContrastTests at 9.36:1. In the chat, older bubbles scroll \
                under the bar as the system intends. Below 200 pt every contrast finding fails.
                """),
        AuditExclusion(
            type: .textClipped,
            labels: [
                "خط إعادة صرف الأدوية في مركزك يرتب لك ذلك، فلا حاجة إلى الحضور.",
                "لا توجد زيارات بعد.",
                "تجريبي — بيانات اصطناعية، غير متصل بأنظمة PHCC/HMC.",
            ],
            reason: """
                Each of these was cropped from a full-resolution screenshot at the frame the audit \
                gave, and each is whole: no clip, no ellipsis, no missing mark. Their glyphs reach the \
                exact edge of the text frame, SF Arabic's at the start and end of the line, and \
                nothing in their containers clips. The crops are in the integration report.
                """),
        AuditExclusion(
            type: .textClipped, labels: ["Al Wakra Health Centre"], above: 160,
            reason: """
                S09's title, whose semibold final e reaches the frame's trailing edge. Cropped at full \
                resolution it is whole. The same name lower down, on S03 and S08, passes.
                """),
        AuditExclusion(
            type: .textClipped, identifier: "settings-server",
            reason: """
                The Settings server field, empty or holding http://192.168.1.20:8100, which fits with \
                room to spare and shows whole in the screenshots at default size and AX3. The finding \
                stayed with the address typed, with monospaced digits, and with the card's clip \
                removed, so it is not ours to fix in the layout. Its error text and the S02 fields, \
                which share DSTextField, pass.
                """),
    ]

    /// The table, plus the sheet over S09, which is not a screen of its own, and three states whose
    /// parts appear nowhere else.
    private var cases: [ScreenCase] {
        ScreenTable.all + [
            ScreenCase(
                name: "s09-door-sheet", arguments: ["-demoScreen", "s09", "-demoFreeze", "1", "-demoSheet", "door"],
                screen: "door-sheet", back: .none),
            ScreenCase(
                name: "s08-suggestion",
                arguments: ["-demoScreen", "s08", "-demoFreeze", "1", "-demoView", "list", "-demoPatch", "suggestion"],
                screen: "screen-centre", back: .home),
            ScreenCase(
                name: "settings-connected",
                arguments: ["-demoScreen", "settings", "-demoMode", "server", "-demoAddress", "http://192.168.1.20:8100",
                            "-demoServer", "ok", "-demoConnect", "1"],
                screen: "screen-settings", back: .pushed),
            ScreenCase(
                name: "s10-demo-waiting",
                arguments: ["-demoScreen", "s10", "-demoFreeze", "1", "-demoPatch", "demoWaiting", "-demoStep", "1"],
                screen: "screen-ticket", back: .home),
        ]
    }

    @MainActor
    private func audit(lang: String) throws {
        var report: [String] = []
        // `TEST_RUNNER_AUDIT_ONLY=s01,s03-active-visit` narrows a local rerun. Unset, all run.
        let only = ProcessInfo.processInfo.environment["AUDIT_ONLY"].map { $0.split(separator: ",").map(String.init) }
        for row in cases where only?.contains(row.name) ?? true {
            let app = XCUIApplication()
            // The app caps text at AX3, which the brief promises and the screenshots review. The
            // audit asks for AX5, so it would report every text as partly unsupported. With the
            // cap lifted, a finding means text that does not scale, or an element capped on purpose.
            app.launchArguments = ["-demoLang", lang, "-demoTypeCap", "off"] + row.arguments
            app.launch()
            guard app.element(row.screen).waitForExistence(timeout: 15) else {
                report.append("\(row.name) \(lang): \(row.screen) never appeared")
                continue
            }
            // Let a staged state settle, such as a send that fails or an override that lands, and
            // the chat's scroll to its newest message, which at 2 s had not always finished.
            sleep(4)
            for finding in try app.auditFindings(excluding: exclusions) {
                report.append("\(row.name) \(lang): \(finding)")
            }
            app.terminate()
        }
        XCTAssertTrue(report.isEmpty, "\n" + report.joined(separator: "\n"))
    }

    @MainActor
    func testEveryScreenInEnglish() throws {
        try audit(lang: "en")
    }

    @MainActor
    func testEveryScreenInArabic() throws {
        try audit(lang: "ar")
    }
}
