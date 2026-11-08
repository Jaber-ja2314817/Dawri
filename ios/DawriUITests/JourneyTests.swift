import XCTest

/// Fatima, Ahmed and Ravi, walked with real taps from S01 on the clinic on this phone, in Arabic
/// and English. Each launch passes only `-demoLang` and `-demoFreeze 0`: no `-demoScreen`, no
/// `-demoControls` and no staging hook, so every screen is reached the way a patient reaches it,
/// and the outcome comes from the real rules and the real demo clinic. The demo clinic's own
/// timer also runs, as it does on a phone, so a step can land between two taps. The patient
/// types every chat line into the box and taps the real Send.
final class JourneyTests: XCTestCase {
    private enum Copy {
        static let validEN = "Check-in valid for 45 minutes"
        static let validAR = "تسجيل الوصول صالح لمدة 45 دقيقة"
        static let wakraEN = "Al Wakra Health Centre"
        static let wakraAR = "مركز الوكرة الصحي"
        static let sentToEmergencyEN = "Sent to emergency"
        static let sentToEmergencyAR = "حُوّلت إلى الطوارئ"
        static let laylaEN = "This visit is for Layla Al-Demo."
    }

    /// What Fatima says, and her answer to anything more the receptionist asks.
    private static func fatimaLines(_ lang: String) -> [String] {
        lang == "ar"
            ? ["عندي حرارة وكحة من ثلاث أيام", "6", "بنادول", "لا"]
            : ["I have a fever and cough for three days", "6", "panadol", "no"]
    }

    private static func decline(_ lang: String) -> String {
        lang == "ar" ? "لا" : "no"
    }

    /// Penicillin and the two penicillins the demo formulary holds, in both scripts.
    private static let penicillins = [
        "penicillin", "amoxicillin", "amoxiclav", "co-amoxiclav", "بنسلين", "البنسلين", "أموكسي", "اموكسي",
    ]

    override func setUp() {
        continueAfterFailure = false
    }

    // Steps

    @MainActor
    private func start(_ lang: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-demoLang", lang, "-demoFreeze", "0"]
        app.launch()
        assertShown(app.element("screen-welcome"), "S01")
        return app
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ format: String, _ args: [Any] = [], timeout: TimeInterval = 15,
                         file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) never matched \(format) \(args)", file: file, line: line)
    }

    /// S01, S02 and a quick-pick chip, then S03 with its record loaded.
    @MainActor
    private func logIn(_ app: XCUIApplication, chip: String) {
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"), "S02")
        app.element("chip-\(chip)").tap()
        assertShown(app.element("screen-home"), "S03")
        waitFor(app.element("home-start"), "isEnabled == true")
    }

    /// Start check-in, S04 when there is someone else to book for, then Consent.
    @MainActor
    private func checkIn(_ app: XCUIApplication, for person: String?) {
        app.element("home-start").tap()
        if let person {
            assertShown(app.element("screen-who"), "S04")
            app.element("who-\(person)").tap()
        }
        assertShown(app.element("screen-consent"), "Consent")
        app.element("consent-agree").tap()
    }

    /// Types one line into the box and taps Send. `typeText` enters Arabic on this simulator, so
    /// no hook fills the box.
    @MainActor
    private func say(_ text: String, in app: XCUIApplication) {
        let input = app.element("chat-input")
        assertShown(input)
        waitFor(app.element("chat-thinking"), "exists == false")
        input.tap()
        input.typeText(text)
        let send = app.element("chat-send")
        waitFor(send, "isEnabled == true")
        send.tap()
    }

    /// Bubbles on screen now.
    @MainActor
    private func bubbles(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: "bubble").count
    }

    /// Answers until the read-back card shows, then Yes. Every line goes through the rules.
    @MainActor
    private func chatToSummary(_ app: XCUIApplication, lang: String) {
        assertShown(app.element("screen-chat"), "S05")
        var lines = Self.fatimaLines(lang)
        for _ in 0..<10 {
            if app.element("chat-summary").exists { break }
            let before = bubbles(app)
            say(lines.isEmpty ? Self.decline(lang) : lines.removeFirst(), in: app)
            // The patient's bubble, then the receptionist's next question or the card.
            let moved = NSPredicate { _, _ in
                app.element("chat-summary").exists || self.bubbles(app) >= before + 2
            }
            wait(for: [expectation(for: moved, evaluatedWith: nil)], timeout: 15)
        }
        assertShown(app.element("chat-summary"), "the read-back")
        waitFor(app.element("chat-summary-yes"), "isEnabled == true")
        app.element("chat-summary-yes").tap()
    }

    /// No ticket number and no queue figure anywhere on screen.
    @MainActor
    private func assertNoNumber(_ app: XCUIApplication, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(app.element("ticket-number").exists, "\(context): a ticket number", file: file, line: line)
        XCTAssertFalse(app.element("ticket-card").exists, "\(context): a ticket block", file: file, line: line)
        XCTAssertFalse(app.element("people-ahead").exists, "\(context): people ahead", file: file, line: line)
        let numbered = NSPredicate(format: "label MATCHES %@", ".*[A-Z]-([A-Z]+-)?[0-9]{3}.*")
        XCTAssertEqual(
            app.staticTexts.matching(numbered).count, 0, "\(context): a ticket-shaped number", file: file, line: line)
    }

    // Fatima

    /// Chip, Start check-in, S04, Me, Consent, the chat to the read-back, Yes, S08 at her own
    /// centre, S09 with no number, I'm here, S10 at T-014, Back to Home and in again, then
    /// Demo: next step through the doctor and the pharmacy to S11, medicines with no penicillin,
    /// a rating, Home and History.
    @MainActor
    private func fatima(_ lang: String) {
        let app = start(lang)
        logIn(app, chip: "P001")
        checkIn(app, for: "P001")
        chatToSummary(app, lang: lang)

        assertShown(app.element("screen-centre"), "S08")
        let wakra = lang == "ar" ? Copy.wakraAR : Copy.wakraEN
        assertShown(app.staticTexts[wakra], "her registered centre is chosen")
        app.element("check-in-here").tap()

        assertShown(app.element("screen-reserved"), "S09")
        assertShown(app.element("screen-reserved").staticTexts[wakra], "S09 is at her registered centre")
        assertShown(app.element("reserved-valid"))
        XCTAssertEqual(app.element("reserved-valid").label, lang == "ar" ? Copy.validAR : Copy.validEN)
        assertNoNumber(app, "S09")
        app.element("im-here").tap()

        assertShown(app.element("screen-ticket"), "S10")
        let number = app.element("ticket-number")
        assertShown(number)
        XCTAssertEqual(number.value as? String, "T-014", "Fatima's first number on a fresh clinic")

        // One Back from S10 is Home: the stage moves replaced every screen on the way.
        app.backControl.tap()
        assertShown(app.element("screen-home"), "Back from S10")
        XCTAssertFalse(app.backControl.exists, "Home is the stack root")
        assertShown(app.element("open-visit"))
        app.element("open-visit").tap()
        assertShown(app.element("screen-ticket"), "the open visit row")

        // The demo clinic, from its labelled control. Its timer may also move a step.
        var seen: [String] = []
        for _ in 0..<40 {
            if app.element("screen-complete").exists { break }
            if let shown = app.element("ticket-number").value as? String, app.element("ticket-number").exists,
               seen.last != shown {
                seen.append(shown)
            }
            let step = app.element("demo-next-step")
            if step.exists, step.isEnabled, step.isHittable {
                step.tap()
            }
            _ = app.element("screen-complete").waitForExistence(timeout: 1)
        }
        assertShown(app.element("screen-complete"), "S11 after the demo steps, numbers \(seen)")
        XCTAssertTrue(seen.contains("D-GP-023"), "the doctor's number, seen \(seen)")
        XCTAssertTrue(seen.contains("P-031"), "the pharmacy's number, seen \(seen)")

        let medicines = app.element("medicines").descendants(matching: .any).matching(identifier: "medicine")
        XCTAssertGreaterThan(medicines.count, 0, "the pharmacy gave medicines")
        for index in 0..<medicines.count {
            let label = medicines.element(boundBy: index).label.lowercased()
            for drug in Self.penicillins {
                XCTAssertFalse(label.contains(drug), "Fatima is allergic to penicillin: \(label)")
            }
        }
        XCTAssertFalse(app.element("no-medicines").exists)

        let stars = app.descendants(matching: .any).matching(identifier: "rate-star")
        XCTAssertEqual(stars.count, 5)
        stars.element(boundBy: 4).tap()
        assertShown(app.element("rating-read-only"), "the rating was sent")

        app.element("complete-home").tap()
        assertShown(app.element("screen-home"), "Home from S11")
        app.element("home-history").tap()
        assertShown(app.element("screen-history"), "S12")
        let row = app.descendants(matching: .any).matching(identifier: "history-row").firstMatch
        assertShown(row, "the visit is in History")
        XCTAssertTrue(row.label.contains(wakra), "History names the centre: \(row.label)")
    }

    @MainActor
    func testFatimaInArabic() {
        fatima("ar")
    }

    @MainActor
    func testFatimaInEnglish() {
        fatima("en")
    }

    /// Fatima books for her daughter: Consent and S10 name the child, and the visit runs to S11.
    @MainActor
    func testFatimaForADependent() {
        let app = start("en")
        logIn(app, chip: "P001")
        app.element("home-start").tap()
        assertShown(app.element("screen-who"), "S04")
        app.element("who-P004").tap()
        assertShown(app.element("screen-consent"))
        XCTAssertEqual(app.element("consent-for").label, Copy.laylaEN)
        app.element("consent-agree").tap()
        chatToSummary(app, lang: "en")
        assertShown(app.element("screen-centre"), "S08")
        app.element("check-in-here").tap()
        assertShown(app.element("screen-reserved"), "S09")
        assertNoNumber(app, "S09")
        app.element("im-here").tap()
        assertShown(app.element("screen-ticket"), "S10")
        assertShown(app.element("visit-for"))
        XCTAssertTrue(app.element("visit-for").label.contains("Layla Al-Demo"), app.element("visit-for").label)
        assertShown(app.element("ticket-number"))
        for _ in 0..<40 {
            if app.element("screen-complete").exists { break }
            let step = app.element("demo-next-step")
            if step.exists, step.isEnabled, step.isHittable { step.tap() }
            _ = app.element("screen-complete").waitForExistence(timeout: 1)
        }
        assertShown(app.element("screen-complete"), "S11 for Layla")
    }

    // Ahmed

    /// Chip, Consent with no S04, his sentence reaches S07 with no ticket and no number, Message
    /// your centre shows the notice, and I still want a visit reaches S08.
    @MainActor
    private func ahmed(_ lang: String) {
        let app = start(lang)
        logIn(app, chip: "P002")
        checkIn(app, for: nil)
        assertShown(app.element("screen-chat"), "S05")
        say(lang == "ar" ? "أبي حبوب الضغط المعتادة" : "I need my usual blood pressure tablets.", in: app)

        assertShown(app.element("screen-refill"), "S07")
        assertNoNumber(app, "S07")
        XCTAssertFalse(app.element("refill-notice").exists)
        app.element("refill-message").tap()
        assertShown(app.element("refill-notice"), "the notice")
        assertNoNumber(app, "S07 with the notice")
        app.element("refill-visit").tap()
        assertShown(app.element("screen-centre"), "I still want a visit")
        app.backControl.tap()
        assertShown(app.element("screen-home"), "one Back from S08 is Home")
    }

    @MainActor
    func testAhmedInArabic() {
        ahmed("ar")
    }

    @MainActor
    func testAhmedInEnglish() {
        ahmed("en")
    }

    // Ravi

    /// Chip, Consent, his sentence opens S06 at once with Call 999 ready and no ticket. The
    /// override shows the staff route, Go to home reaches S03 with the emergency row, and a new
    /// Start check-in comes back to S06 with no chat on the way.
    @MainActor
    private func ravi(_ lang: String) {
        let app = start(lang)
        logIn(app, chip: "P003")
        checkIn(app, for: nil)
        assertShown(app.element("screen-chat"), "S05")
        say(lang == "ar" ? "عندي ألم في الصدر ينتشر إلى ذراعي" : "Chest pain going to my left arm.", in: app)

        let cover = app.element("screen-emergency")
        assertShown(cover, "S06")
        let call = cover.descendants(matching: .any)["emergency-call"].firstMatch
        assertShown(call)
        XCTAssertTrue(call.isHittable, "Call 999 can be tapped")
        XCTAssertFalse(app.backControl.isHittable, "S06 has no back")
        assertNoNumber(app, "S06")

        let override = cover.descendants(matching: .any)["emergency-override"].firstMatch
        assertShown(override)
        override.tap()
        assertShown(cover.descendants(matching: .any)["emergency-route"].firstMatch, "the staff route")
        assertNoNumber(app, "S06 after the override")
        cover.descendants(matching: .any)["emergency-home"].firstMatch.tap()

        assertShown(app.element("screen-home"), "Go to home")
        waitFor(app.element("screen-emergency"), "exists == false")
        let row = app.element("open-visit")
        assertShown(row, "today's emergency row")
        let status = lang == "ar" ? Copy.sentToEmergencyAR : Copy.sentToEmergencyEN
        XCTAssertTrue(row.label.contains(status), row.label)

        app.element("home-start").tap()
        if app.element("screen-consent").waitForExistence(timeout: 5) {
            app.element("consent-agree").tap()
        }
        assertShown(app.element("screen-emergency"), "a new check-in today comes back to S06")
        XCTAssertFalse(app.element("screen-chat").exists, "no new chat")
        XCTAssertFalse(app.element("chat-input").exists, "no new chat")
    }

    @MainActor
    func testRaviInArabic() {
        ravi("ar")
    }

    @MainActor
    func testRaviInEnglish() {
        ravi("en")
    }
}
