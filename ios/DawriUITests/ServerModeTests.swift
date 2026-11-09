import XCTest

/// The live proof of Clinic server mode, against a real Dawri backend in simulated mode on this
/// Mac. Only `ios/Tools/server-proof.sh` runs these, through the DawriServer scheme: it starts the
/// server with ios/Tools/clinic-server.sh (blank HF_TOKEN, 127.0.0.1, a temp database, and only
/// after /api/health said simulated) and hands its address to this runner as `DAWRI_SERVER`,
/// through xcodebuild's `TEST_RUNNER_DAWRI_SERVER`. The Dawri scheme skips this class.
///
/// The patient side is the app, with real taps. The staff side is this runner, which calls the
/// staff API on the same 127.0.0.1 server, as the web's consoles would, and as the helpers in
/// backend/tests/test_api_e2e.py do. This file and DawriCore's Clinic server client are the only
/// places that open a network session. It never contacts any other host, and it never calls the
/// speech upload path.
///
/// After each staff call the change must show on screen within 10 s, with no pull to refresh, no
/// relaunch and no navigation. Each moment is recorded, with the time of the call and the time it
/// was seen, in a `timings-*` attachment and on the log as `SERVER-PROOF` lines, and every stage
/// is attached as a screenshot.
final class ServerModeTests: XCTestCase {
    private enum Copy {
        static let wakraEN = "Al Wakra Health Centre"
        static let wakraAR = "مركز الوكرة الصحي"
        static let clinicServer = ["Clinic server", "خادم العيادة"]
        static let onThisPhone = ["On this phone", "على هذا الهاتف"]
    }

    /// The longest a staff move may take to show on the phone.
    private static let liveLimit: TimeInterval = 10

    /// Penicillin and the two penicillins the demo formulary holds, in both scripts.
    private static let penicillins = [
        "penicillin", "amoxicillin", "amoxiclav", "co-amoxiclav", "بنسلين", "البنسلين", "أموكسي", "اموكسي",
    ]

    private var desk: StaffDesk!
    private var timings: [String] = []

    override func setUp() async throws {
        continueAfterFailure = false
        let base = try Self.serverFromEnvironment()
        let desk = await StaffDesk(base: base)
        // The simulated-mode check first: nothing else is sent to a server that fails it.
        let mode = try await desk.aiMode()
        guard mode == "simulated" else {
            XCTFail("REFUSED: \(base)/api/health says ai_mode \(mode.debugDescription), not simulated. Nothing else was sent.")
            throw Refused()
        }
        try await desk.reset()
        self.desk = desk
    }

    private struct Refused: Error {}

    /// `DAWRI_SERVER`, which must be `http://127.0.0.1:<8101-8199>`. Missing or anything else
    /// fails the test with the reason. It is never skipped.
    private static func serverFromEnvironment() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["DAWRI_SERVER"], !text.isEmpty else {
            XCTFail("""
                DAWRI_SERVER is not set, so there is no Clinic server to test against. Run \
                ios/Tools/server-proof.sh <outdir>, which starts a simulated server on 127.0.0.1 and \
                passes TEST_RUNNER_DAWRI_SERVER=<url> to xcodebuild.
                """)
            throw Refused()
        }
        guard text.wholeMatch(of: #/http://127\.0\.0\.1:81(0[1-9]|[1-9][0-9])/#) != nil, let url = URL(string: text)
        else {
            XCTFail("DAWRI_SERVER must be http://127.0.0.1:8101-8199, as clinic-server.sh starts it, not \(text.debugDescription)")
            throw Refused()
        }
        return url
    }

    // The patient's side

    @MainActor
    private func waitFor(
        _ element: XCUIElement, _ format: String, _ args: [Any] = [], timeout: TimeInterval = 15,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let predicate = NSPredicate(format: format, argumentArray: args)
        let result = XCTWaiter().wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
        XCTAssertEqual(result, .completed, "\(element) never matched \(format) \(args)", file: file, line: line)
    }

    @MainActor
    private func shot(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// One of the segments, by its label in either language, so the order in RTL does not matter.
    @MainActor
    private func segment(_ app: XCUIApplication, _ labels: [String]) -> XCUIElement {
        app.element("settings-mode").buttons.matching(NSPredicate(format: "label IN %@", labels)).firstMatch
    }

    /// Settings: Clinic server, the address typed over whatever was there, Connect, Connected.
    @MainActor
    private func connect(_ app: XCUIApplication, lang: String) {
        assertShown(app.element("screen-settings"), "Settings")
        let server = segment(app, Copy.clinicServer)
        assertShown(server)
        server.tap()
        let field = app.element("settings-server")
        assertShown(field)
        field.tap()
        let old = (field.value as? String) ?? ""
        if !old.isEmpty, old != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count + 4))
        }
        field.typeText(desk.base.absoluteString)
        shot(app, "\(lang)-01-settings-typed")
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-ok"), "Connected")
        assertShown(app.element("settings-server-in-use"), "the in-use line")
        XCTAssertTrue(
            app.element("settings-server-in-use").label.contains(desk.base.absoluteString),
            "the in-use line names the server: \(app.element("settings-server-in-use").label)")
        XCTAssertFalse(app.element("settings-reset").exists, "Reset is On this phone only")
        shot(app, "\(lang)-02-settings-connected")
    }

    /// S01, S02 and Fatima's quick-pick chip, which signs in with OTP 0000, then S03.
    @MainActor
    private func logIn(_ app: XCUIApplication, lang: String) {
        assertShown(app.element("screen-welcome"), "S01, signed out on the server")
        app.element("welcome-login").tap()
        assertShown(app.element("screen-login"), "S02")
        let chip = app.element("chip-P001")
        assertShown(chip, "the server's quick-pick chips")
        shot(app, "\(lang)-03-login")
        chip.tap()
        assertShown(app.element("screen-home"), "S03")
        waitFor(app.element("home-start"), "isEnabled == true")
        shot(app, "\(lang)-04-home")
    }

    @MainActor
    private func bubbles(_ app: XCUIApplication) -> Int {
        app.descendants(matching: .any).matching(identifier: "bubble").count
    }

    /// Consent, then the chat with ClinicContract's sentences to the read-back, and Yes.
    @MainActor
    private func chat(_ app: XCUIApplication, lang: String) {
        app.element("home-start").tap()
        assertShown(app.element("screen-who"), "S04")
        app.element("who-P001").tap()
        assertShown(app.element("screen-consent"), "Consent")
        app.element("consent-agree").tap()
        assertShown(app.element("screen-chat"), "S05")
        var lines = lang == "ar"
            ? ["عندي حرارة وكحة من ثلاث أيام", "6", "بنادول", "لا"]
            : ["I have a fever and cough for three days", "6", "panadol", "no"]
        for _ in 0..<10 {
            if app.element("chat-summary").exists { break }
            let before = bubbles(app)
            let input = app.element("chat-input")
            assertShown(input)
            waitFor(app.element("chat-thinking"), "exists == false")
            input.tap()
            input.typeText(lines.isEmpty ? (lang == "ar" ? "لا" : "no") : lines.removeFirst())
            let send = app.element("chat-send")
            waitFor(send, "isEnabled == true")
            send.tap()
            let moved = NSPredicate { _, _ in
                app.element("chat-summary").exists || self.bubbles(app) >= before + 2
            }
            wait(for: [expectation(for: moved, evaluatedWith: nil)], timeout: 20)
        }
        assertShown(app.element("chat-summary"), "the read-back")
        shot(app, "\(lang)-05-chat-read-back")
        waitFor(app.element("chat-summary-yes"), "isEnabled == true")
        app.element("chat-summary-yes").tap()
    }

    /// S08 at Al Wakra, reserve, S09, I'm here, S10 with the server's number.
    @MainActor
    private func toTicket(_ app: XCUIApplication, lang: String) {
        assertShown(app.element("screen-centre"), "S08")
        let wakra = lang == "ar" ? Copy.wakraAR : Copy.wakraEN
        assertShown(app.staticTexts[wakra], "her registered centre")
        shot(app, "\(lang)-06-s08-centre")
        app.element("check-in-here").tap()
        assertShown(app.element("screen-reserved"), "S09")
        XCTAssertFalse(app.element("ticket-number").exists, "a reserved ticket has no number")
        shot(app, "\(lang)-07-s09-reserved")
        app.element("im-here").tap()
        assertShown(app.element("screen-ticket"), "S10")
        let number = app.element("ticket-number")
        assertShown(number)
        waitFor(number, "value == %@", ["T-014"])
        XCTAssertFalse(app.element("demo-next-step").exists, "Demo: next step is On this phone only")
        shot(app, "\(lang)-08-s10-T-014")
    }

    /// The whole patient side, from Settings to S10.
    @MainActor
    private func toTicketFromSettings(_ app: XCUIApplication, lang: String) {
        connect(app, lang: lang)
        app.backControl.tap()
        logIn(app, lang: lang)
        chat(app, lang: lang)
        toTicket(app, lang: lang)
    }

    // The staff side, timed

    /// One staff move, then the change it must make on screen, within 10 s.
    @MainActor
    private func staffMove(
        _ name: String, lang: String, in app: XCUIApplication, move: () async throws -> Void,
        shows: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        try await move()
        let called = Date()
        var seen: Date?
        while Date().timeIntervalSince(called) < Self.liveLimit {
            if shows() {
                seen = Date()
                break
            }
            try await Task.sleep(for: .milliseconds(150))
        }
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = seen.map { String(format: "%.2f", $0.timeIntervalSince(called)) } ?? "never"
        let record = "SERVER-PROOF lang=\(lang) step=\(name) staff-call-returned=\(format.string(from: called)) "
            + "seen-on-screen=\(seen.map(format.string(from:)) ?? "never") seconds=\(seconds)"
        print(record)
        timings.append(record)
        XCTAssertNotNil(seen, "\(name): not on screen within \(Int(Self.liveLimit)) s of the staff call", file: file, line: line)
        if seen == nil { throw Refused() }
        // Outside the measured time: the stage change animates, so the screenshot and the next
        // move wait for it to finish.
        try await Task.sleep(for: .milliseconds(1_500))
    }

    @MainActor
    private func number(_ app: XCUIApplication) -> String? {
        let element = app.element("ticket-number")
        return element.exists ? element.value as? String : nil
    }

    @MainActor
    private func attachTimings(_ lang: String) {
        let attachment = XCTAttachment(string: timings.joined(separator: "\n") + "\n")
        attachment.name = "timings-\(lang)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Nurse call-next, vitals, the handoff, and the doctor's call-next. Returns the visit and
    /// the doctor's session.
    @MainActor
    private func throughTheDoctorsCall(
        _ app: XCUIApplication, lang: String
    ) async throws -> (visitId: String, doctor: StaffDesk.Session) {
        let nurse = try await desk.login("S-WAK-NURSE1")
        var visitId = ""
        try await staffMove("nurse-call-next", lang: lang, in: app, move: {
            let called = try await self.desk.post("/api/counters/C-WAKRA-T1/call-next", token: nurse.token)
            let ticket = called["called"] as? [String: Any]
            XCTAssertEqual(ticket?["number"] as? String, "T-014")
            visitId = try XCTUnwrap(ticket?["visit_id"] as? String)
        }, shows: { app.element("ticket-called").exists })
        shot(app, "\(lang)-09-s10-called")

        let visit = "/api/visits/\(visitId)"
        try await staffMove("vitals", lang: lang, in: app, move: {
            let served = try await self.desk.post("\(visit)/vitals", token: nurse.token, body: [
                "bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "spo2": 98, "urgency": "routine",
            ])
            XCTAssertEqual((served["ticket"] as? [String: Any])?["state"] as? String, "serving")
        }, shows: { app.element("ticket-serving").exists })
        shot(app, "\(lang)-10-s10-serving")

        var doctorId = ""
        var counter = ""
        try await staffMove("handoff-confirm", lang: lang, in: app, move: {
            let draft = try await self.desk.post("\(visit)/handoff/draft", token: nurse.token)
            let first = try XCTUnwrap((draft["suggestions"] as? [[String: Any]])?.first)
            doctorId = try XCTUnwrap(first["doctor_id"] as? String)
            counter = try XCTUnwrap(first["counter_id"] as? String)
            let moved = try await self.desk.post("\(visit)/handoff/confirm", token: nurse.token, body: [
                "final_text": try XCTUnwrap(draft["text"] as? String), "doctor_id": doctorId,
            ])
            XCTAssertEqual((moved["ticket"] as? [String: Any])?["number"] as? String, "D-GP-023")
        }, shows: { self.number(app) == "D-GP-023" && !app.element("ticket-serving").exists })
        shot(app, "\(lang)-11-s10-doctor-D-GP-023")

        let doctor = try await desk.login(doctorId)
        try await staffMove("doctor-call-next", lang: lang, in: app, move: {
            let called = try await self.desk.post("/api/counters/\(counter)/call-next", token: doctor.token)
            XCTAssertEqual((called["called"] as? [String: Any])?["number"] as? String, "D-GP-023")
        }, shows: { app.element("ticket-called").exists && self.number(app) == "D-GP-023" })
        shot(app, "\(lang)-12-s10-doctor-called")
        return (visitId, doctor)
    }

    // The tests

    /// Fatima in English, the whole visit, moved only by staff API calls.
    @MainActor
    func testFatimaInEnglishThroughEveryStaffStep() async throws {
        let app = launch("-demoLang", "en", "-demoScreen", "settings", "-demoFreeze", "0")
        toTicketFromSettings(app, lang: "en")
        let (visitId, doctor) = try await throughTheDoctorsCall(app, lang: "en")
        let visit = "/api/visits/\(visitId)"

        try await staffMove("consult-done", lang: "en", in: app, move: {
            // PRESCRIPTION in backend/tests/test_api_e2e.py: nothing a penicillin allergy conflicts with.
            let done = try await self.desk.post("\(visit)/consult/done", token: doctor.token, body: [
                "prescription": [["drug_id": "DR-PARA"], ["drug_id": "DR-DEXT"]],
            ])
            XCTAssertEqual((done["ticket"] as? [String: Any])?["number"] as? String, "P-031")
        }, shows: { self.number(app) == "P-031" && !app.element("ticket-called").exists })
        shot(app, "en-13-s10-pharmacy-P-031")

        let pharmacist = try await desk.login("S-WAK-PHARM1")
        try await staffMove("pharmacist-call-next", lang: "en", in: app, move: {
            let called = try await self.desk.post("/api/counters/C-WAKRA-P1/call-next", token: pharmacist.token)
            XCTAssertEqual((called["called"] as? [String: Any])?["number"] as? String, "P-031")
        }, shows: { app.element("ticket-called").exists && self.number(app) == "P-031" })
        shot(app, "en-14-s10-pharmacy-called")

        try await staffMove("dispensed", lang: "en", in: app, move: {
            let finished = try await self.desk.post("\(visit)/dispensed", token: pharmacist.token)
            XCTAssertEqual(finished["status"] as? String, "completed")
        }, shows: { app.element("screen-complete").exists })
        attachTimings("en")

        let medicines = app.element("medicines").descendants(matching: .any).matching(identifier: "medicine")
        waitFor(app.element("medicines"), "exists == true")
        XCTAssertGreaterThan(medicines.count, 0, "the pharmacy's medicines are on S11")
        for index in 0..<medicines.count {
            let label = medicines.element(boundBy: index).label.lowercased()
            for drug in Self.penicillins {
                XCTAssertFalse(label.contains(drug), "Fatima is allergic to penicillin: \(label)")
            }
        }
        XCTAssertFalse(app.element("no-medicines").exists)
        shot(app, "en-15-s11-complete")
    }

    /// Fatima in Arabic, launched straight into Clinic server mode, through called and the
    /// doctor's stage and call.
    @MainActor
    func testFatimaInArabicThroughTheDoctor() async throws {
        let app = launch(
            "-demoLang", "ar", "-demoClinic", desk.base.absoluteString, "-demoScreen", "settings",
            "-demoFreeze", "0")
        assertShown(app.element("settings-server-ok"), "Connected after a launch in server mode")
        assertShown(app.element("settings-server-in-use"))
        XCTAssertFalse(app.element("settings-reset").exists, "Reset is On this phone only")
        shot(app, "ar-02-settings-in-use")
        app.backControl.tap()
        logIn(app, lang: "ar")
        chat(app, lang: "ar")
        toTicket(app, lang: "ar")
        _ = try await throughTheDoctorsCall(app, lang: "ar")
        attachTimings("ar")
    }

    /// The stream forced down: the visit still moves, by polling, and S10 says it is slower.
    @MainActor
    func testWithTheStreamDownAStaffMoveArrivesByPolling() async throws {
        let app = launch(
            "-demoLang", "en", "-demoClinic", desk.base.absoluteString, "-demoFail", "visitUpdates=network",
            "-demoFreeze", "0")
        logIn(app, lang: "en-polling")
        chat(app, lang: "en-polling")
        toTicket(app, lang: "en-polling")
        assertShown(app.element("freshness"), "the slow line, with the stream down")
        shot(app, "en-polling-09-s10-slow")

        let nurse = try await desk.login("S-WAK-NURSE1")
        try await staffMove("nurse-call-next-by-polling", lang: "en-polling", in: app, move: {
            let called = try await self.desk.post("/api/counters/C-WAKRA-T1/call-next", token: nurse.token)
            XCTAssertEqual((called["called"] as? [String: Any])?["number"] as? String, "T-014")
        }, shows: { app.element("ticket-called").exists })
        XCTAssertTrue(app.element("freshness").exists, "still by polling")
        shot(app, "en-polling-10-s10-called-by-polling")
        attachTimings("en-polling")
    }

    /// A normal launch, with no launch hook: Connect saves the server and the session token goes
    /// to the Keychain, a relaunch stays in server mode, signed in, and reads health again, and
    /// On this phone switches back. This is the only test here on the phone's own settings, so it
    /// ends back On this phone.
    @MainActor
    func testARelaunchStaysOnTheServerUntilOnThisPhone() async throws {
        let app = XCUIApplication()
        app.launch()
        let gear = app.element("settings-gear")
        assertShown(gear, "S01 or S03")
        gear.tap()
        connect(app, lang: "relaunch")
        app.backControl.tap()
        logIn(app, lang: "relaunch")

        app.terminate()
        app.launch()
        assertShown(app.element("screen-home"), "signed in again from the Keychain, on the server")
        shot(app, "relaunch-05-home-after-relaunch")
        app.element("settings-gear").tap()
        assertShown(app.element("settings-server-ok"), "Connected after the relaunch")
        assertShown(app.element("settings-server-in-use"))
        XCTAssertTrue(app.element("settings-server-in-use").label.contains(desk.base.absoluteString))
        shot(app, "relaunch-06-settings-after-relaunch")

        segment(app, Copy.onThisPhone).tap()
        assertShown(app.element("settings-reset"), "back on this phone at once")
        XCTAssertFalse(app.element("settings-server-in-use").exists)
        XCTAssertFalse(app.element("settings-server").exists)
        shot(app, "relaunch-07-back-on-the-phone")

        app.terminate()
        app.launch()
        assertShown(app.element("settings-gear"))
        app.element("settings-gear").tap()
        assertShown(app.element("settings-reset"), "a relaunch stays On this phone")
        XCTAssertFalse(app.element("settings-server-in-use").exists)
    }
}

/// The staff side: the staff API on the test's own 127.0.0.1 server, and nothing else. No
/// redirect is followed, and nothing is cached or stored.
@MainActor
private final class StaffDesk {
    struct Session {
        let token: String
    }

    let base: URL
    private let session: URLSession

    init(base: URL) {
        precondition(base.scheme == "http" && base.host == "127.0.0.1", "staff calls go to 127.0.0.1 only")
        self.base = base
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func aiMode() async throws -> String? {
        try await call("GET", "/api/health", token: nil)["ai_mode"] as? String
    }

    func reset() async throws {
        let nurse = try await login("S-WAK-NURSE1")
        let answer = try await post("/api/demo/reset", token: nurse.token)
        guard answer["ok"] as? Bool == true else { throw StaffError(message: "reset: \(answer)") }
    }

    func login(_ staffId: String) async throws -> Session {
        let answer = try await post("/api/staff/login", token: nil, body: ["staff_id": staffId])
        guard let token = answer["token"] as? String else { throw StaffError(message: "no staff session for \(staffId)") }
        return Session(token: token)
    }

    func post(_ path: String, token: String?, body: [String: Any]? = nil) async throws -> [String: Any] {
        try await call("POST", path, token: token, body: body)
    }

    private func call(_ method: String, _ path: String, token: String?, body: [String: Any]? = nil) async throws -> [String: Any] {
        precondition(path.hasPrefix("/api/"))
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL, url.host == base.host, url.port == base.port
        else { throw StaffError(message: "refused \(path)") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw StaffError(message: "\(method) \(path) gave \(status): \(String(decoding: data, as: UTF8.self))")
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    struct StaffError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
