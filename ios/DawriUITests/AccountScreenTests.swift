import XCTest

/// S02, S03, S04, Consent, S12 and Settings, walked with real taps on the clinic on this phone.
/// `debug-path`, `debug-read` and `debug-calls` come from `-demoControls 1`, and only report:
/// no control here carries a patient past a step.
final class AccountScreenTests: XCTestCase {
    private enum Text {
        static let unknownQid = "No demo patient has this QID."
        static let invalidOtp = "That code is not correct."
        static let refusedHost = "This app does not connect to that host."
        static let refusedAi = "This server is not in simulated mode, so the app will not use it."
        static let unreachable = "We could not reach this server."
        static let connected = "Connected, simulated mode"
        static let refusedAddress = "Type only the server's address, with no path. Plain http works only on your local network. Use https for anything else."
        static let inUse = "The app is using this clinic server: http://192.168.1.20:8100"
        static let resetConfirm = "This clears the visits on this phone."
        static let reset = "Reset demo data"
        static let forLayla = "This visit is for Layla Al-Demo."
        static let sentToEmergency = "Sent to emergency"
    }

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
    private func calls(_ route: String, in app: XCUIApplication) -> Int {
        let pairs = app.element("debug-calls").label.split(separator: " ")
        let pair = pairs.first { $0.hasPrefix("\(route):") }
        return pair.flatMap { Int($0.dropFirst(route.count + 1)) } ?? 0
    }

    @MainActor
    private func waitFor(_ element: XCUIElement, _ format: String, _ value: Any? = nil, timeout: TimeInterval = 10) {
        let predicate = value.map { NSPredicate(format: format, argumentArray: [$0]) } ?? NSPredicate(format: format)
        wait(for: [expectation(for: predicate, evaluatedWith: element)], timeout: timeout)
    }

    @MainActor
    private func gone(_ element: XCUIElement, timeout: TimeInterval = 10) {
        waitFor(element, "exists == false", timeout: timeout)
    }

    /// One `key=value` of `debug-read`.
    @MainActor
    private func read(_ key: String, in app: XCUIApplication) -> String? {
        app.element("debug-read").tap()
        waitFor(app.element("debug-status"), "label BEGINSWITH 'stage='")
        for pair in app.element("debug-status").label.split(separator: " ") {
            let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2, parts[0] == key { return parts[1] }
        }
        return nil
    }

    // S02

    @MainActor
    func testEachChipLogsIn() {
        for (chip, name) in [("P001", "Fatima Al-Demo"), ("P002", "Ahmed Al-Demo"), ("P003", "Ravi Demo")] {
            let app = start(["-demoLang", "en", "-demoScreen", "s02"])
            assertShown(app.element("chip-\(chip)"), chip)
            app.element("chip-\(chip)").tap()
            assertShown(app.element("screen-home"), chip)
            waitFor(app.element("home-name"), "label == %@", name)
            XCTAssertFalse(app.backControl.exists, "\(chip): a pushed Home")
            app.terminate()
        }
    }

    @MainActor
    func testSubmitWaitsForBothFields() {
        let app = start(["-demoLang", "en", "-demoScreen", "s02"])
        assertShown(app.element("login-submit"))
        XCTAssertFalse(app.element("login-submit").isEnabled)
        app.element("login-qid").tap()
        app.typeText("DEMO-10002")
        XCTAssertFalse(app.element("login-submit").isEnabled, "enabled with no code")
        app.element("login-otp").tap()
        app.typeText("0000")
        waitFor(app.element("login-submit"), "isEnabled == true")
        app.element("login-submit").tap()
        waitFor(app.element("home-name"), "label == %@", "Ahmed Al-Demo")
    }

    @MainActor
    func testAnUnknownQidShowsUnderTheQid() {
        let app = start(["-demoLang", "en", "-demoScreen", "s02"])
        assertShown(app.element("login-otp"))
        app.element("login-otp").tap()
        app.typeText("0000")
        app.element("login-qid").tap()
        app.typeText("DEMO-99999\n")
        assertShown(app.element("login-qid-error"))
        XCTAssertEqual(app.element("login-qid-error").label, Text.unknownQid)
        XCTAssertFalse(app.element("login-otp-error").exists)
        XCTAssertFalse(app.element("login-error").exists, "a field error is not an error block")
        XCTAssertTrue(app.element("screen-login").exists)
    }

    @MainActor
    func testAWrongCodeShowsUnderTheCode() {
        let app = start(["-demoLang", "en", "-demoScreen", "s02"])
        assertShown(app.element("login-otp"))
        app.element("login-otp").tap()
        app.typeText("1234")
        app.element("login-qid").tap()
        app.typeText("DEMO-10001\n")
        assertShown(app.element("login-otp-error"))
        XCTAssertEqual(app.element("login-otp-error").label, Text.invalidOtp)
        XCTAssertFalse(app.element("login-qid-error").exists)
        XCTAssertFalse(app.element("login-error").exists)
    }

    /// Anything else is an error block, and its retry sends the same attempt again.
    @MainActor
    func testANetworkFailureRetriesTheSameAttempt() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s02", "-demoFailOnce", "authStart=network",
            "-demoControls", "1",
        ])
        assertShown(app.element("chip-P003"))
        app.element("chip-P003").tap()
        assertShown(app.element("login-error"))
        XCTAssertFalse(app.element("login-qid-error").exists)
        app.element("login-error").buttons.firstMatch.tap()
        waitFor(app.element("home-name"), "label == %@", "Ravi Demo")
        XCTAssertEqual(calls("authStart", in: app), 2)
    }

    /// A language switch re-renders S02 in place, so what was typed stays.
    @MainActor
    func testALanguageSwitchKeepsTypedText() {
        let app = start(["-demoLang", "en", "-demoScreen", "s02"])
        assertShown(app.element("login-qid"))
        app.element("login-qid").tap()
        app.typeText("DEMO-10001")
        app.element("language-toggle").tap()
        assertShown(app.staticTexts[Copy.loginTitleAR])
        XCTAssertEqual(app.element("login-qid").value as? String, "DEMO-10001")
        XCTAssertTrue(app.element("screen-login").exists)
    }

    // S03 to Consent

    /// Ahmed has nobody else to book for, so Start check-in goes straight to Consent.
    @MainActor
    func testAhmedSkipsWho() {
        let app = start(["-demoLang", "en", "-demoScreen", "s02", "-demoControls", "1"])
        assertShown(app.element("chip-P002"))
        app.element("chip-P002").tap()
        assertShown(app.element("home-start"))
        waitFor(app.element("home-start"), "isEnabled == true")
        app.element("home-start").tap()
        assertShown(app.element("screen-consent"))
        XCTAssertFalse(app.element("screen-who").exists)
        XCTAssertFalse(app.element("consent-for").exists, "Ahmed is booking for himself")
        XCTAssertTrue(app.element("debug-path").label.contains("consent"))
        XCTAssertFalse(app.element("debug-path").label.contains("who"))
        app.backControl.tap()
        assertShown(app.element("screen-home"))
    }

    /// Fatima chooses between herself and her dependents, and Consent names the child.
    @MainActor
    func testFatimaSeesDependentsAndConsentsForAChild() {
        let app = start(["-demoLang", "en", "-demoScreen", "s02", "-demoControls", "1"])
        assertShown(app.element("chip-P001"))
        app.element("chip-P001").tap()
        assertShown(app.element("home-start"))
        waitFor(app.element("home-start"), "isEnabled == true")
        app.element("home-start").tap()
        assertShown(app.element("screen-who"))
        for id in ["who-P001", "who-P004", "who-P005"] {
            assertShown(app.element(id), id)
        }
        app.element("who-P004").tap()
        assertShown(app.element("screen-consent"))
        XCTAssertEqual(app.element("consent-for").label, Text.forLayla)

        app.backControl.tap()
        assertShown(app.element("screen-who"), "Back from Consent goes to S04")
        app.element("who-P004").tap()
        assertShown(app.element("consent-agree"))
        app.element("consent-agree").tap()
        waitFor(app.element("debug-path"), "label CONTAINS 'chat'")
        let path = app.element("debug-path").label
        XCTAssertFalse(path.contains("consent"), "Consent stayed under the chat: \(path)")
        XCTAssertFalse(path.contains("who"), "S04 stayed under the chat: \(path)")
    }

    /// Ravi's emergency stands for the day: Consent opens S06 for it, and no new visit or chat.
    @MainActor
    func testEmergencyTodayFromConsentOpensS06() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s04", "-demoPatient", "DEMO-10003", "-demoStage", "emergency",
            "-demoFreeze", "1", "-demoControls", "1",
        ])
        // Ravi has no dependents, so S04 is Consent from its first frame.
        assertShown(app.element("consent-agree"))
        XCTAssertFalse(app.element("screen-who").exists)
        app.element("consent-agree").tap()
        assertShown(app.element("screen-emergency"))
        waitFor(app.element("debug-path"), "label CONTAINS 'emergency('")
        XCTAssertFalse(app.element("debug-path").label.contains("chat"))
        // The engine refused the visit, so none was made, and nothing was sent to a chat.
        XCTAssertEqual(calls("createVisit", in: app), 1)
        XCTAssertEqual(calls("sendChat", in: app), 0)
    }

    /// Fatima already has a ticket: Consent opens that visit, never a second chat.
    @MainActor
    func testActiveVisitFromConsentOpensThatVisit() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "consent", "-demoPatient", "DEMO-10001", "-demoFreeze", "1",
            "-demoControls", "1",
        ])
        assertShown(app.element("consent-agree"))
        app.element("consent-agree").tap()
        waitFor(app.element("debug-path"), "label CONTAINS 'ticket'")
        let path = app.element("debug-path").label
        XCTAssertFalse(path.contains("chat"), path)
        XCTAssertFalse(path.contains("consent"), path)
        XCTAssertEqual(read("rows", in: app), "triage", "a second visit was made")
        app.backControl.tap()
        assertShown(app.element("screen-home"))
    }

    @MainActor
    func testAConsentFailureRetries() {
        let app = start([
            // `-demoScreen consent` is Consent for P001, so the patient is Fatima, with her visit done.
            "-demoLang", "en", "-demoScreen", "consent", "-demoPatient", "DEMO-10001", "-demoStage", "completed",
            "-demoFreeze", "1", "-demoFailOnce", "createVisit=network", "-demoControls", "1",
        ])
        assertShown(app.element("consent-agree"))
        app.element("consent-agree").tap()
        assertShown(app.element("consent-error"))
        app.element("consent-error").buttons.firstMatch.tap()
        waitFor(app.element("debug-path"), "label CONTAINS 'chat'")
        XCTAssertEqual(calls("createVisit", in: app), 2)
    }

    // S03

    @MainActor
    func testHomeShowsTheRecordAndTheOpenVisit() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s03", "-demoPatient", "DEMO-10001", "-demoFreeze", "1",
        ])
        assertShown(app.element("open-visit"))
        assertShown(app.element("home-record"))
        XCTAssertTrue(app.element("home-allergies").label.contains("Penicillin"))
        app.element("open-visit").tap()
        assertShown(app.backControl)
        app.backControl.tap()
        assertShown(app.element("open-visit"), "the list did not come back")
    }

    @MainActor
    func testAhmedHasNoAllergiesAndNoVisit() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s03", "-demoPatient", "DEMO-10002", "-demoFresh", "1",
        ])
        assertShown(app.element("home-record"))
        XCTAssertTrue(app.element("home-allergies").label.contains("None recorded"))
        XCTAssertFalse(app.element("open-visit").exists)
    }

    /// Today's emergency row goes straight to S06, with no chat on the way.
    @MainActor
    func testAnEmergencyRowOpensS06() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s03", "-demoPatient", "DEMO-10003", "-demoStage", "emergency",
            "-demoFreeze", "1", "-demoControls", "1",
        ])
        assertShown(app.element("open-visit"))
        XCTAssertTrue(app.element("open-visit").label.contains(Text.sentToEmergency))
        app.element("open-visit").tap()
        assertShown(app.element("screen-emergency"))
        XCTAssertFalse(app.element("debug-path").label.contains("chat"))
    }

    // S12

    @MainActor
    func testHistoryOpensOnlyCompletedRowsAndBackReturnsToIt() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s12", "-demoPatient", "DEMO-10002", "-demoHistory", "mixed",
            "-demoFreeze", "1", "-demoControls", "1",
        ])
        assertShown(app.element("history-row"))
        let rows = app.descendants(matching: .any).matching(identifier: "history-row")
        waitFor(rows.element(boundBy: 3), "exists == true")
        XCTAssertEqual(rows.count, 4)
        let opening = app.buttons.matching(identifier: "history-row")
        XCTAssertEqual(opening.count, 1, "only the completed row opens")
        opening.firstMatch.tap()
        waitFor(app.element("debug-path"), "label CONTAINS 'complete'")
        XCTAssertTrue(app.element("debug-path").label.hasPrefix("history"))
        app.backControl.tap()
        assertShown(app.element("screen-history"))
    }

    @MainActor
    func testAnEmptyHistoryOffersCheckIn() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s12", "-demoPatient", "DEMO-10002", "-demoFresh", "1",
        ])
        assertShown(app.element("history-empty"))
        waitFor(app.element("history-start"), "isEnabled == true")
        app.element("history-start").tap()
        assertShown(app.element("screen-consent"))
    }

    // Settings

    /// The guard runs before any request: a Hugging Face host never reaches the probe.
    @MainActor
    func testARefusedHostShowsTheMessageWithNoProbe() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "ok",
            "-demoControls", "1",
        ])
        assertShown(app.element("settings-server"))
        assertShown(app.element("settings-server-limit"))
        app.element("settings-server").tap()
        app.typeText("https://User@Dawri.HF.Space.:443")
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-error"))
        XCTAssertEqual(app.element("settings-server-error").label, Text.refusedHost)
        XCTAssertFalse(app.element("settings-server-ok").exists)
        sleep(1)
        XCTAssertEqual(calls("probe", in: app), 0, "the probe was called for a refused host")
    }

    /// The plain form of a Space address, as the owner's own Space has it, in both languages.
    @MainActor
    func testAPlainSpaceAddressIsRefusedWithNoProbe() {
        for (lang, message) in [("en", Text.refusedHost), ("ar", "لا يتصل هذا التطبيق بهذا العنوان.")] {
            let app = start([
                "-demoLang", lang, "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "ok",
                "-demoAddress", "https://dawri.hf.space", "-demoControls", "1",
            ])
            assertShown(app.element("settings-connect"))
            app.element("settings-connect").tap()
            assertShown(app.element("settings-server-error"))
            XCTAssertEqual(app.element("settings-server-error").label, message, lang)
            XCTAssertFalse(app.element("settings-server-ok").exists, lang)
            XCTAssertFalse(app.element("settings-server-in-use").exists, "\(lang): the app moved to that host")
            sleep(1)
            XCTAssertEqual(calls("probe", in: app), 0, "\(lang): the probe was called for a Space address")
        }
    }

    /// The same probe does answer a local address, so the zero above is not a broken counter.
    @MainActor
    func testALocalAddressReachesTheProbe() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "ok",
            "-demoAddress", "http://192.168.1.20:8100", "-demoControls", "1",
        ])
        assertShown(app.element("settings-connect"))
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-ok"))
        XCTAssertEqual(app.element("settings-server-ok").label, Text.connected)
        XCTAssertEqual(calls("probe", in: app), 1)
    }

    @MainActor
    func testAServerNotInSimulatedModeIsRefused() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "refusedAi",
            "-demoAddress", "http://192.168.1.20:8100",
        ])
        assertShown(app.element("settings-connect"))
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-error"))
        XCTAssertEqual(app.element("settings-server-error").label, Text.refusedAi)
        XCTAssertFalse(app.element("settings-server-ok").exists)
    }

    @MainActor
    func testAnUnreachableServer() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "unreachable",
            "-demoAddress", "http://192.168.1.20:8100",
        ])
        assertShown(app.element("settings-connect"))
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-error"))
        XCTAssertEqual(app.element("settings-server-error").label, Text.unreachable)
    }

    /// With no `-demoServer`, the app's own probe, `ServerHealthProbe`, on a closed port of this
    /// Mac's loopback: nothing answers, so it says unreachable and the app stays on this phone.
    /// The only request it can make goes to 127.0.0.1.
    @MainActor
    func testTheAppsOwnProbeFindsNothingOnAClosedPort() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server",
            "-demoAddress", "http://127.0.0.1:9",
        ])
        assertShown(app.element("settings-connect"))
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-error"))
        XCTAssertEqual(app.element("settings-server-error").label, Text.unreachable)
        XCTAssertFalse(app.element("settings-server-ok").exists)
        XCTAssertFalse(app.element("settings-server-in-use").exists, "the app moved to a server")
    }

    /// `http` to a public host, or a path, is refused before any request, with the plainer
    /// message, and the probe is never called.
    @MainActor
    func testAPublicHttpAddressIsRefusedWithNoProbe() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "ok",
            "-demoAddress", "http://example.com", "-demoControls", "1",
        ])
        assertShown(app.element("settings-connect"))
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-error"))
        XCTAssertEqual(app.element("settings-server-error").label, Text.refusedAddress)
        XCTAssertFalse(app.element("settings-server-ok").exists)
        sleep(1)
        XCTAssertEqual(calls("probe", in: app), 0, "the probe was called for a refused address")
    }

    /// Connected moves the app to the server, signed out, with the in-use line and no Reset.
    /// On this phone moves it back at once, with Reset, and the server's line gone.
    @MainActor
    func testConnectUsesTheServerAndOnThisPhoneSwitchesBack() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoMode", "server", "-demoServer", "ok",
            "-demoAddress", "http://192.168.1.20:8100", "-demoControls", "1",
        ])
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-ok"))
        assertShown(app.element("settings-server-in-use"))
        XCTAssertEqual(app.element("settings-server-in-use").label, Text.inUse)
        XCTAssertFalse(app.element("settings-reset").exists)

        app.element("settings-mode").buttons["On this phone"].tap()
        assertShown(app.element("settings-reset"), "back on this phone at once")
        XCTAssertFalse(app.element("settings-server").exists)
        XCTAssertFalse(app.element("settings-server-in-use").exists)
        XCTAssertEqual(calls("probe", in: app), 1, "switching back needs no probe")
    }

    /// The modes never share a session: signed in on this phone, the server starts signed out,
    /// and On this phone comes back to the patient and the open visit.
    @MainActor
    func testTheModesNeverShareASession() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s03", "-demoPatient", "DEMO-10001", "-demoFreeze", "1",
            "-demoServer", "ok", "-demoAddress", "http://192.168.1.20:8100", "-demoMode", "server",
        ])
        assertShown(app.element("open-visit"))
        app.element("settings-gear").tap()
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-in-use"))
        app.backControl.tap()
        assertShown(app.element("screen-welcome"), "the server has no session of this phone's")

        app.element("settings-gear").tap()
        assertShown(app.element("settings-server-in-use"))
        app.element("settings-mode").buttons["On this phone"].tap()
        assertShown(app.element("settings-reset"))
        app.backControl.tap()
        assertShown(app.element("screen-home"), "this phone's session is back")
        assertShown(app.element("open-visit"), "with its open visit")
    }

    /// A refusal while a server is in use leaves the app on that server.
    @MainActor
    func testARefusalKeepsTheServerInUse() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "settings", "-demoClinic", "http://192.168.1.20:8100",
            "-demoServer", "refusedAi", "-demoControls", "1",
        ])
        assertShown(app.element("settings-server-in-use"), "a launch in server mode")
        let field = app.element("settings-server")
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 30))
        field.typeText("http://10.0.0.5:8100")
        app.element("settings-connect").tap()
        assertShown(app.element("settings-server-error"))
        XCTAssertEqual(app.element("settings-server-error").label, Text.refusedAi)
        XCTAssertEqual(app.element("settings-server-in-use").label, Text.inUse, "the app left its server")
        XCTAssertEqual(calls("probe", in: app), 1)
    }

    @MainActor
    func testResetIsOnlyOnThisPhoneAndNotReviewedIsAlwaysShown() {
        let app = start(["-demoLang", "en", "-demoScreen", "settings"])
        assertShown(app.element("settings-reset"))
        assertShown(app.element("settings-not-reviewed"))
        XCTAssertFalse(app.element("settings-server").exists)
        app.element("settings-mode").buttons["Clinic server"].tap()
        assertShown(app.element("settings-server"))
        gone(app.element("settings-reset"))
        XCTAssertTrue(app.element("settings-not-reviewed").exists)
    }

    /// Reset asks first. Cancel keeps the visit, and confirming clears it from S03.
    @MainActor
    func testResetConfirmsFirst() {
        let app = start([
            "-demoLang", "en", "-demoScreen", "s03", "-demoPatient", "DEMO-10001", "-demoFreeze", "1",
        ])
        assertShown(app.element("open-visit"))
        app.element("settings-gear").tap()
        assertShown(app.element("settings-reset"))

        app.element("settings-reset").tap()
        assertShown(app.staticTexts[Text.resetConfirm])
        let cancel = app.buttons["Cancel"]
        if cancel.waitForExistence(timeout: 2) {
            cancel.tap()
        } else {
            // A popover has no Cancel. A tap outside it dismisses it.
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.95)).tap()
        }
        gone(app.staticTexts[Text.resetConfirm])
        app.backControl.tap()
        assertShown(app.element("open-visit"), "Cancel reset the demo")

        app.element("settings-gear").tap()
        assertShown(app.element("settings-reset"))
        app.element("settings-reset").tap()
        assertShown(app.staticTexts[Text.resetConfirm])
        let confirm = app.buttons.matching(
            NSPredicate(format: "label == %@ AND identifier != %@", Text.reset, "settings-reset")
        ).firstMatch
        assertShown(confirm)
        confirm.tap()
        gone(app.staticTexts[Text.resetConfirm])
        app.backControl.tap()
        assertShown(app.element("screen-home"))
        gone(app.element("open-visit"))
        assertShown(app.element("home-record"), "the patient was signed out")
    }

    // The audit for these screens is in AccessibilityAuditTests, over every screen and state.
}
