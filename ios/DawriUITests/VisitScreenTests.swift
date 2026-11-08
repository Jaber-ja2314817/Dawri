import XCTest

/// S08 to S11 on the clinic on this phone. Every step is a real tap on a real screen, through the
/// real engine: no `-demoControls` and no staging hook carries the visit past a step.
final class VisitScreenTests: XCTestCase {
    private let fatima = "DEMO-10001"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func start(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
        return app
    }

    @MainActor
    private func waitFor(
        _ element: XCUIElement, _ format: String, _ args: CVarArg..., timeout: TimeInterval = 10,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) never matched \(format) \(args)", file: file, line: line)
    }

    @MainActor
    private func gone(_ element: XCUIElement, timeout: TimeInterval = 10) {
        waitFor(element, "exists == false", timeout: timeout)
    }

    /// The ticket number as VoiceOver reads it: the value carries the number.
    @MainActor
    private func number(_ app: XCUIApplication) -> String {
        (app.element("ticket-number").value as? String) ?? ""
    }

    /// Taps Demo: next step until the number reads `wanted`, as a patient watching would.
    @MainActor
    private func stepUntilNumber(_ wanted: String, in app: XCUIApplication, _ context: String) {
        for _ in 0..<10 {
            if app.element("ticket-number").exists, number(app) == wanted { return }
            let step = app.element("demo-next-step")
            assertShown(step, context)
            waitFor(step, "isEnabled == true")
            step.tap()
            sleep(1)
        }
        XCTFail("The number never reached \(wanted). \(context)")
    }

    // The whole visit

    /// Fatima from S08 to S11 on a fresh launch: T-014, then D-GP-023, then P-031, through Demo:
    /// next step and the real engine, in both languages.
    @MainActor
    func testFatimaWalksFromCentreToCompleteWithTheDemoControl() {
        for lang in ["en", "ar"] {
            let app = start([
                "-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "s08", "-demoFreeze", "1",
            ])
            assertShown(app.element("screen-centre"), lang)
            assertShown(app.element("check-in-here"), lang)
            app.element("check-in-here").tap()

            assertShown(app.element("screen-reserved"), lang)
            XCTAssertFalse(app.element("ticket-number").exists, lang)
            app.element("im-here").tap()

            assertShown(app.element("screen-ticket"), lang)
            assertShown(app.element("ticket-number"), lang)
            XCTAssertEqual(number(app), "T-014", lang)
            stepUntilNumber("D-GP-023", in: app, lang)
            stepUntilNumber("P-031", in: app, lang)
            for _ in 0..<6 where !app.element("screen-complete").exists {
                if app.element("demo-next-step").exists { app.element("demo-next-step").tap() }
                sleep(1)
            }
            assertShown(app.element("screen-complete"), lang)
            XCTAssertTrue(app.element("final-ticket").label.contains("P-031"), lang)
            XCTAssertFalse(app.element("demo-next-step").exists, "Demo stays on S10. \(lang)")

            // One Back from the end of the visit is Home.
            app.backControl.tap()
            assertShown(app.element("screen-home"), lang)
            app.terminate()
        }
    }

    // S09

    /// A reserved ticket has no number and no place, in both languages.
    @MainActor
    func testTheReservedScreenShowsNoNumberAndNoPeopleAhead() {
        for (lang, valid) in [
            ("en", "Check-in valid for 45 minutes"), ("ar", "تسجيل الوصول صالح لمدة 45 دقيقة"),
        ] {
            let app = start([
                "-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "s09", "-demoFreeze", "1",
            ])
            assertShown(app.element("screen-reserved"), lang)
            XCTAssertEqual(app.element("reserved-valid").label, valid, lang)
            assertShown(app.element("countdown"), lang)
            XCTAssertEqual(app.element("countdown").label, lang == "en" ? "Time left" : "الوقت المتبقي")
            XCTAssertFalse(app.element("ticket-number").exists, lang)
            XCTAssertFalse(app.element("people-ahead").exists, lang)
            XCTAssertFalse(app.element("ticket-card").exists, lang)
            let numbered = NSPredicate(format: "label MATCHES %@", ".*\\b[A-Z]+-[0-9]{3}\\b.*")
            XCTAssertEqual(app.staticTexts.matching(numbered).count, 0, lang)
            for text in ["People ahead", "الأشخاص أمامك", "place", "no-show"] {
                let found = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", text))
                XCTAssertEqual(found.count, 0, "\(text) \(lang)")
            }
            app.terminate()
        }
    }

    /// The countdown runs out on its own, the clinic is asked again, and the same route steps in
    /// place to expired. Back then goes Home, never into the countdown, and so does Back from S08.
    @MainActor
    func testExpiryStepsInPlaceAndBackNeverReturnsToTheCountdown() {
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09", "-demoExpiresIn", "3",
        ])
        assertShown(app.element("screen-reserved"))
        let expired = app.element("reserved-expired")
        XCTAssertTrue(expired.waitForExistence(timeout: 20), "never expired")
        assertShown(app.staticTexts["Check-in expired"])
        gone(app.element("countdown"))

        app.backControl.tap()
        assertShown(app.element("screen-home"))
        XCTAssertFalse(app.element("countdown").exists)
        XCTAssertFalse(app.element("screen-reserved").exists)

        // From Home the open visit is still expired: it opens the expired step, and Choose again
        // replaces it with S08, so Back from there is Home again.
        let row = app.element("open-visit")
        assertShown(row)
        row.tap()
        assertShown(expired)
        app.element("choose-again").tap()
        assertShown(app.element("screen-centre"))
        app.backControl.tap()
        assertShown(app.element("screen-home"))
        XCTAssertFalse(app.element("countdown").exists)
    }

    @MainActor
    func testTooFarGivesTheDistanceAndTheLimit() {
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09", "-demoFreeze", "1",
            "-demoLocation", "far",
        ])
        assertShown(app.element("check-location"))
        app.element("check-location").tap()
        let notice = app.element("too-far")
        assertShown(notice)
        XCTAssertTrue(notice.label.hasPrefix("You are "), notice.label)
        XCTAssertTrue(notice.label.hasSuffix("m from the centre, and check-in works within 150 m."), notice.label)
        XCTAssertTrue(app.element("screen-reserved").exists)
        XCTAssertFalse(app.element("ticket-number").exists)
    }

    @MainActor
    func testAFailedLocationPointsToImHereWhichStillWorks() {
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09", "-demoFreeze", "1",
            "-demoLocation", "fail",
        ])
        assertShown(app.element("check-location"))
        app.element("check-location").tap()
        assertShown(app.element("location-failed"))
        app.element("im-here").tap()
        assertShown(app.element("screen-ticket"))
    }

    /// The typed door code: another centre's code is refused under the field, then the right one,
    /// typed in lower case, checks in.
    @MainActor
    func testAWrongDoorCodeThenTheRightOne() {
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09", "-demoFreeze", "1",
        ])
        assertShown(app.element("reserved-scan"))
        app.element("reserved-scan").tap()
        let field = app.textFields["door-code"]
        assertShown(field)
        field.tap()
        app.typeText("DOOR-C-RAYYAN")
        app.element("door-submit").tap()
        assertShown(app.element("door-code-error"))
        XCTAssertEqual(app.element("door-code-error").label, "This door code belongs to another centre.")
        XCTAssertFalse(app.element("screen-ticket").exists)

        field.tap()
        app.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 20))
        app.typeText("door-c-wakra")
        app.element("door-submit").tap()
        assertShown(app.element("screen-ticket"))
        assertShown(app.element("ticket-number"))
        XCTAssertEqual(number(app), "T-014")
    }

    // S10

    /// No tap at all: the demo clinic's own clock moves the ticket on.
    @MainActor
    func testTheDemoClockMovesATicketWithoutATap() {
        let app = start(["-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10"])
        assertShown(app.element("ticket-number"))
        XCTAssertEqual(number(app), "T-014")
        let moved = NSPredicate { _, _ in
            app.element("ticket-called").exists || app.element("ticket-serving").exists
                || app.element("ticket-next").exists || self.number(app) != "T-014"
        }
        let result = XCTWaiter().wait(
            for: [XCTNSPredicateExpectation(predicate: moved, object: app)], timeout: 60)
        XCTAssertEqual(result, .completed, "the ticket never moved on its own")
    }

    /// Demo: next step is labelled Demo and appears only when the service is the demo clinic.
    @MainActor
    func testTheDemoControlIsLabelledDemoAndOnlyOnThisPhone() {
        for (lang, label) in [("en", "Demo: next step"), ("ar", "تجريبي: الخطوة التالية")] {
            let app = start([
                "-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "s10", "-demoFreeze", "1",
            ])
            assertShown(app.element("demo-next-step"), lang)
            XCTAssertEqual(app.element("demo-next-step").label, label)
            app.terminate()
        }
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10", "-demoFreeze", "1",
            "-demoNoDriver", "1",
        ])
        assertShown(app.element("ticket-number"))
        XCTAssertFalse(app.element("demo-next-step").exists)
    }

    @MainActor
    func testACalledTicketSaysWhereToGoWithNoRows() {
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10", "-demoFreeze", "1",
            "-demoTicket", "called",
        ])
        assertShown(app.element("ticket-called"))
        XCTAssertEqual(app.element("ticket-called").label, "Go to Triage 1 now")
        XCTAssertFalse(app.element("people-ahead").exists)
        XCTAssertFalse(app.element("go-to").exists)
    }

    @MainActor
    func testAZeroIsPrintedAndAnUnknownIsADash() {
        let zero = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10", "-demoFreeze", "1",
            "-demoPatch", "zeroAhead",
        ])
        assertShown(zero.element("people-ahead"))
        XCTAssertTrue(zero.element("people-ahead").label.hasSuffix(", 0"), zero.element("people-ahead").label)
        XCTAssertTrue(zero.element("est-wait").label.hasSuffix(", 0 min"), zero.element("est-wait").label)
        zero.terminate()

        let unknown = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10", "-demoFreeze", "1",
            "-demoPatch", "unknownFigures",
        ])
        assertShown(unknown.element("people-ahead"))
        for id in ["people-ahead", "est-wait"] {
            let label = unknown.element(id).label
            XCTAssertTrue(label.hasSuffix("Not known yet"), label)
            XCTAssertFalse(label.contains("0"), label)
        }
    }

    // S11

    @MainActor
    func testARatingIsSentOnceAndThenReadOnly() {
        let app = start([
            "-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s11", "-demoFreeze", "1",
        ])
        let stars = app.buttons.matching(identifier: "rate-star")
        assertShown(stars.firstMatch)
        XCTAssertEqual(stars.count, 5)
        stars.element(boundBy: 3).tap()
        assertShown(app.element("rating-read-only"))
        XCTAssertEqual(app.element("rating-stars").label, "4 out of 5")
        XCTAssertEqual(app.buttons.matching(identifier: "rate-star").count, 0)
        sleep(2)
        XCTAssertEqual(app.buttons.matching(identifier: "rate-star").count, 0, "read again, still read-only")
    }

    /// Fatima is allergic to penicillin, so the demo clinic never gives her one.
    @MainActor
    func testFatimasMedicinesHoldNoPenicillinInEitherLanguage() {
        for lang in ["en", "ar"] {
            let app = start([
                "-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "s11", "-demoFreeze", "1",
            ])
            let medicines = app.descendants(matching: .any).matching(identifier: "medicine")
            assertShown(medicines.firstMatch, lang)
            XCTAssertGreaterThan(medicines.count, 0, lang)
            for index in 0..<medicines.count {
                let label = medicines.element(boundBy: index).label.lowercased()
                for banned in ["amoxicillin", "co-amoxiclav", "أموكسيسيلين", "كلافولانيك", "penicillin", "بنسلين"] {
                    XCTAssertFalse(label.contains(banned), "\(banned) in \(label)")
                }
            }
            app.terminate()
        }
    }

    /// When the demo clinic cannot move, because someone real stands ahead, the control says so
    /// in Demo's own words, and the number stays where it was.
    @MainActor
    func testDemoWaitingSaysNothingMoved() {
        for (lang, text) in [
            ("en", "Demo: nothing moved, someone is ahead of you."),
            ("ar", "تجريبي: لم يتغير شيء، يوجد شخص قبلك."),
        ] {
            let app = start([
                "-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "s10", "-demoFreeze", "1",
                "-demoPatch", "demoWaiting",
            ])
            assertShown(app.element("demo-next-step"), lang)
            let number = app.element("ticket-number").value as? String
            XCTAssertFalse(app.element("demo-waiting").exists, lang)
            app.element("demo-next-step").tap()
            assertShown(app.element("demo-waiting"), lang)
            XCTAssertEqual(app.element("demo-waiting").label, text)
            XCTAssertEqual(app.element("ticket-number").value as? String, number, lang)
            app.terminate()
        }
    }

    // The audit for these screens is in AccessibilityAuditTests, over every screen and state.
}
