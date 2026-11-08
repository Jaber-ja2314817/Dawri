import XCTest

/// What `-demoLiveProbe 1` reports: the activities the system shows, the pending notices, the
/// notification permission and the demo plan of the visit being followed. Written out here from
/// the probe's text, so a test checks the app against the plan with its own reading of it.
struct LiveProbeReading: Equatable {
    struct Activity: Equatable {
        let visitId: String
        let number: String?
        let stage: String
        let ticketState: String?
        let lang: String
        let ahead: Int?
    }

    struct Notice: Equatable {
        let id: String
        let offset: Int?
        let key: String
    }

    struct Step: Equatable {
        let index: Int
        let kind: String
        let stage: String
        /// Seconds until due, or nil once it has run.
        let offset: Int?
    }

    let raw: String
    let activities: [Activity]
    let pending: [Notice]
    let auth: String
    let followed: String?
    let plan: [Step]

    init(_ raw: String) {
        self.raw = raw
        var fields: [String: String] = [:]
        for part in raw.components(separatedBy: " | ") {
            guard let equals = part.firstIndex(of: "=") else { continue }
            fields[String(part[..<equals])] = String(part[part.index(after: equals)...])
        }
        func items(_ name: String) -> [String] {
            (fields[name] ?? "").split(separator: ";").map(String.init)
        }
        func optional(_ text: String) -> String? { text == "-" ? nil : text }
        activities = items("activities").compactMap { item in
            let parts = item.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 6 else { return nil }
            return Activity(
                visitId: parts[0], number: optional(parts[1]), stage: parts[2],
                ticketState: optional(parts[3]), lang: parts[4], ahead: Int(parts[5]))
        }
        pending = items("pending").compactMap { item in
            let parts = item.split(separator: "@").map(String.init)
            guard parts.count == 3 else { return nil }
            return Notice(id: parts[0], offset: Int(parts[1]), key: parts[2])
        }
        auth = fields["auth"] ?? ""
        followed = fields["followed"].flatMap(optional)
        plan = items("plan").compactMap { item in
            let halves = item.split(separator: "@").map(String.init)
            let parts = halves.first?.split(separator: ":").map(String.init) ?? []
            guard halves.count == 2, parts.count == 3, let index = Int(parts[0]) else { return nil }
            return Step(index: index, kind: parts[1], stage: parts[2], offset: Int(halves[1]))
        }
    }

    /// The probe has answered at least once.
    var isRead: Bool { raw.contains("activities=") }

    /// The notice a plan step should give, as section 9 of iOS Design says, written out here.
    static func key(for step: Step) -> String? {
        switch step.kind {
        case "call_triage", "call_doctor", "call_pharmacy": "notify.next"
        case "to_doctor": "notify.stage"
        case "consult": step.stage == "pharmacy" ? "notify.stage" : nil
        default: nil
        }
    }
}

extension XCTestCase {
    @MainActor
    func probe(_ app: XCUIApplication) -> LiveProbeReading {
        LiveProbeReading((app.element("live-probe").value as? String) ?? "")
    }

    /// Waits until the probe reads true for `check`, and returns that reading.
    @MainActor
    @discardableResult
    func waitForProbe(
        _ app: XCUIApplication, timeout: TimeInterval = 15, _ what: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ check: @escaping (LiveProbeReading) -> Bool
    ) -> LiveProbeReading {
        let deadline = Date().addingTimeInterval(timeout)
        var last = probe(app)
        while Date() < deadline {
            last = probe(app)
            if last.isRead, check(last) { return last }
            usleep(250_000)
        }
        XCTFail("The probe never showed \(what). Last: \(last.raw)", file: file, line: line)
        return last
    }

    /// The probe keeps reading true for `check` for the whole of `seconds`.
    @MainActor
    func holdProbe(
        _ app: XCUIApplication, for seconds: TimeInterval, _ what: String,
        file: StaticString = #filePath, line: UInt = #line,
        _ check: (LiveProbeReading) -> Bool
    ) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let reading = probe(app)
            if reading.isRead, !check(reading) {
                XCTFail("The probe stopped showing \(what): \(reading.raw)", file: file, line: line)
                return
            }
            usleep(250_000)
        }
    }

    /// The demo control, once it is ready, then a moment for the visit to be read again.
    @MainActor
    func tapDemoNextStep(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        let step = app.element("demo-next-step")
        XCTAssertTrue(step.waitForExistence(timeout: 10), "no Demo: next step", file: file, line: line)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: step)
        XCTAssertEqual(XCTWaiter().wait(for: [enabled], timeout: 10), .completed, file: file, line: line)
        step.tap()
    }
}

/// The ticket's Live Activity, read through the DEBUG probe, which lists what the system itself
/// has running. Every launch is on a frozen demo clock, so only Demo: next step moves a visit.
///
/// The probe proves the app started, updated and ended the activity through ActivityKit. How the
/// Lock Screen and the real Dynamic Island draw it is for the phone, and the live-gallery and
/// live-island shots.
final class LiveActivityTests: XCTestCase {
    private let fatima = "DEMO-10001"
    private let ravi = "DEMO-10003"

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func start(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = arguments + ["-demoFreeze", "1", "-demoLiveProbe", "1"]
        app.launch()
        return app
    }

    @MainActor
    private func ticketNumber(_ app: XCUIApplication) -> String {
        (app.element("ticket-number").value as? String) ?? ""
    }

    /// A staged S10 has exactly one activity: this visit's, with its number, stage and language.
    /// Any left by an earlier run were ended at launch.
    @MainActor
    func testAStagedTicketHasExactlyOneActivityWithItsNumber() {
        for lang in ["en", "ar"] {
            let app = start(["-demoLang", lang, "-demoPatient", fatima, "-demoScreen", "s10"])
            assertShown(app.element("ticket-number"), lang)
            XCTAssertEqual(ticketNumber(app), "T-014", lang)
            let reading = waitForProbe(app, "one T-014 activity in \(lang)") {
                $0.activities.count == 1 && $0.activities.first?.number == "T-014"
            }
            let activity = reading.activities.first
            XCTAssertEqual(activity?.stage, "triage", lang)
            XCTAssertEqual(activity?.ticketState, "active", lang)
            XCTAssertEqual(activity?.lang, lang)
            XCTAssertEqual(activity?.visitId, reading.followed, lang)
            holdProbe(app, for: 3, "exactly one activity") { $0.activities.count == 1 }
            app.terminate()
        }
    }

    /// Demo: next step moves the activity with the screen: the queue, then the call, then a new
    /// number at the doctor.
    @MainActor
    func testDemoNextStepUpdatesTheActivity() {
        let app = start(["-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10"])
        let first = waitForProbe(app, "the T-014 activity") { $0.activities.first?.number == "T-014" }
        let before = first.activities.first

        tapDemoNextStep(app)
        waitForProbe(app, "a change after one step") { reading in
            guard let now = reading.activities.first else { return false }
            return reading.activities.count == 1 && now != before
        }

        // On to the call: the activity says called, still with T-014.
        for _ in 0..<8 where probe(app).activities.first?.ticketState != "called" {
            tapDemoNextStep(app)
            sleep(1)
        }
        let called = waitForProbe(app, "the called state") { $0.activities.first?.ticketState == "called" }
        XCTAssertEqual(called.activities.first?.number, "T-014")
        assertShown(app.element("ticket-called"))

        // On to the doctor: a new number and stage, in the same one activity.
        for _ in 0..<8 where probe(app).activities.first?.stage != "doctor" {
            tapDemoNextStep(app)
            sleep(1)
        }
        let doctor = waitForProbe(app, "the doctor's ticket") {
            $0.activities.first?.stage == "doctor" && $0.activities.first?.number == "D-GP-023"
        }
        XCTAssertEqual(doctor.activities.count, 1)
        XCTAssertEqual(doctor.activities.first?.visitId, first.activities.first?.visitId)
    }

    /// Walked to the end, the visit completes and its activity ends: nothing is left showing as
    /// active. The ended one stays on the Lock Screen for 15 minutes, which only a phone shows.
    @MainActor
    func testCompletionEndsTheActivity() {
        let app = start(["-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s10"])
        waitForProbe(app, "the T-014 activity") { $0.activities.count == 1 }
        for _ in 0..<20 where !app.element("screen-complete").exists {
            if app.element("demo-next-step").exists, app.element("demo-next-step").isEnabled {
                app.element("demo-next-step").tap()
            }
            sleep(1)
        }
        assertShown(app.element("screen-complete"))
        waitForProbe(app, "no activity after completion") { $0.activities.isEmpty }
        holdProbe(app, for: 3, "no activity") { $0.activities.isEmpty }
    }

    /// A reserved ticket has no number, so there is no activity, before or after a while.
    @MainActor
    func testAReservedTicketHasNoActivity() {
        let app = start(["-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09"])
        assertShown(app.element("screen-reserved"))
        waitForProbe(app, "a first reading") { _ in true }
        holdProbe(app, for: 4, "no activity while reserved") { $0.activities.isEmpty }
    }

    /// Arrival is the moment it starts: S09 has none, and I'm here starts exactly one.
    @MainActor
    func testArrivalStartsTheActivity() {
        let app = start(["-demoLang", "en", "-demoPatient", fatima, "-demoScreen", "s09"])
        assertShown(app.element("im-here"))
        waitForProbe(app, "no activity yet") { $0.activities.isEmpty }
        app.element("im-here").tap()
        assertShown(app.element("screen-ticket"))
        waitForProbe(app, "one activity after arrival") {
            $0.activities.count == 1 && $0.activities.first?.number != nil
        }
    }

    /// Ravi's chest pain is an emergency: no ticket, so no activity, in either language.
    @MainActor
    func testRavisEmergencyHasNoActivity() {
        for lang in ["en", "ar"] {
            let app = start(["-demoLang", lang, "-demoPatient", ravi, "-demoScreen", "s06"])
            assertShown(app.element("screen-emergency"), lang)
            waitForProbe(app, "a first reading") { _ in true }
            holdProbe(app, for: 4, "no activity on an emergency") { $0.activities.isEmpty }
            app.terminate()
        }
    }

    /// The activity's language is fixed for its life, so a language switch ends it and starts
    /// one in the new language: still exactly one, now in the new language, with the same number.
    @MainActor
    func testALanguageSwitchRestartsItInTheNewLanguage() {
        let app = start(["-demoLang", "ar", "-demoPatient", fatima, "-demoScreen", "s10"])
        let arabic = waitForProbe(app, "the Arabic activity") {
            $0.activities.count == 1 && $0.activities.first?.lang == "ar"
        }
        assertShown(app.element("language-toggle"))
        app.element("language-toggle").tap()
        let english = waitForProbe(app, "the English activity") {
            $0.activities.count == 1 && $0.activities.first?.lang == "en"
        }
        XCTAssertEqual(english.activities.first?.number, "T-014")
        XCTAssertEqual(english.activities.first?.visitId, arabic.activities.first?.visitId)
        holdProbe(app, for: 3, "exactly one English activity") {
            $0.activities.count == 1 && $0.activities.first?.lang == "en"
        }

        // And back again.
        app.element("language-toggle").tap()
        waitForProbe(app, "the Arabic activity again") {
            $0.activities.count == 1 && $0.activities.first?.lang == "ar"
        }
    }
}
