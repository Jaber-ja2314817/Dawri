import Foundation
import Testing
@testable import DawriCore

@Suite("ClinicError and errorText")
struct ClinicErrorTests {
    private let strings = Strings.bundled

    @Test func `a real error body with no Arabic`() throws {
        let error = ClinicError(status: 401, body: try Fixture.data("api_error"))
        #expect(error.status == 401)
        #expect(error.code == "invalid_otp")
        #expect(error.message == "That code is not correct.")
        #expect(error.messageAr == nil)
        #expect(error.extra.isEmpty)
    }

    @Test func `a real error body with Arabic keeps the rest as extra`() throws {
        let error = ClinicError(status: 409, body: try Fixture.data("api_error_ar"))
        #expect(error.code == "emergency_today")
        #expect(error.messageAr?.isEmpty == false)
        guard case .string? = error.extra["visit_id"] else {
            Issue.record("visit_id should stay in extra")
            return
        }
        #expect(error.extra["message_ar"] == nil)
        #expect(error.extra["error"] == nil)
    }

    @Test(arguments: ["<html>proxy</html>", "", "[]", #"{"detail": "x"}"#, "null"])
    func `a body that is not ours is an internal error`(body: String) {
        let error = ClinicError(status: 502, body: Data(body.utf8))
        #expect(error.status == 502)
        #expect(error.code == "internal_error")
        #expect(error.message == "Unexpected response from the server.")
    }

    @Test func `a missing message falls back to the code`() {
        let error = ClinicError(status: 400, body: Data(#"{"error": "x", "message": 7}"#.utf8))
        #expect(error.message == "x")
    }

    @Test func `the server's Arabic comes first on an Arabic screen`() {
        let error = ClinicError(status: 409, code: "invalid_otp", message: "English", messageAr: "عربي")
        #expect(errorText(error, strings: strings, lang: .ar) == "عربي")
        #expect(errorText(error, strings: strings, lang: .en) == "English")
    }

    @Test func `raw English never lands on an Arabic screen`() {
        let error = ClinicError(status: 401, code: "invalid_otp", message: "That code is not correct.")
        let text = errorText(error, strings: strings, lang: .ar)
        #expect(text == strings.translate(.ar, "error.invalid_otp"))
        #expect(text != error.message)
        #expect(text.unicodeScalars.contains { (0x0600...0x06FF).contains($0.value) })
    }

    @Test func `the code's sentence is next`() {
        let error = ClinicError(status: 401, code: "invalid_otp", message: "Raw")
        #expect(errorText(error, strings: strings, lang: .en) == "That code is not correct.")
    }

    @Test(arguments: [Lang.ar, .en])
    func `an unknown code is the generic sentence`(lang: Lang) {
        let error = ClinicError(status: 500, code: "no_such_code", message: "Raw English")
        #expect(errorText(error, strings: strings, lang: lang)
            == strings.translate(lang, "error.generic"))
    }

    @Test(arguments: [Lang.ar, .en])
    func `any other error is the generic sentence`(lang: Lang) {
        #expect(errorText(CancellationError(), strings: strings, lang: lang)
            == strings.translate(lang, "error.generic"))
    }

    @Test func `a lost connection has its own sentence`() {
        #expect(errorText(ClinicError.network, strings: strings, lang: .en)
            == strings.translate(.en, "error.network"))
    }
}

@Suite("StubClinicService smoke")
struct StubTests {
    private func next(_ iterator: inout AsyncStream<VisitUpdate>.Iterator) async -> VisitUpdate? {
        await iterator.next(isolation: nil)
    }

    @Test func `health says simulated`() async {
        #expect(await StubClinicService().health().aiMode == .simulated)
    }

    @Test func `the demo patients are the real three`() async {
        let patients = await StubClinicService().demoPatients()
        #expect(patients.map(\.id) == ["P001", "P002", "P003"])
        #expect(patients.map(\.qidDemo) == ["DEMO-10001", "DEMO-10002", "DEMO-10003"])
        #expect(patients.map(\.fullNameEn) == ["Fatima Al-Demo", "Ahmed Al-Demo", "Ravi Demo"])
        #expect(patients.map(\.fullNameAr) == ["فاطمة التجريبية", "أحمد التجريبي", "رافي"])
    }

    @Test func `login with OTP 0000, refused otherwise`() async throws {
        let service = StubClinicService()
        #expect(await service.isSignedIn == false)
        #expect(try await service.authStart(qid: "DEMO-10001").otpSent)
        await #expect(throws: ClinicError(
            status: 401, code: "invalid_otp", message: "That code is not correct."
        )) {
            try await service.authVerify(qid: "DEMO-10001", otp: "1234")
        }
        #expect(await service.isSignedIn == false)
        let patient = try await service.authVerify(qid: "DEMO-10001", otp: "0000")
        #expect(patient.id == "P001")
        #expect(await service.isSignedIn)
        await service.signOut()
        #expect(await service.isSignedIn == false)
    }

    @Test func `an unknown QID is refused`() async {
        await #expect {
            try await StubClinicService().authStart(qid: "DEMO-99999")
        } throws: { error in
            (error as? ClinicError)?.code == "unknown_qid"
        }
    }

    @Test func `Fatima has dependents and Ravi does not`() async throws {
        let service = StubClinicService()
        _ = try await service.authVerify(qid: "DEMO-10001", otp: "0000")
        #expect(checkInRoute(try await service.getMe()) == .who)
        _ = try await service.authVerify(qid: "DEMO-10003", otp: "0000")
        #expect(checkInRoute(try await service.getMe()) == .consent(patientId: "P003"))
    }

    @Test(arguments: VisitStage.allCases, [false, true])
    func `starts at any stage with any flag`(stage: VisitStage, confirmed: Bool) async throws {
        let service = StubClinicService(stage: stage, confirmedByPatient: confirmed)
        let visit = try await service.getVisit(visitId: StubClinicService.startingVisitId)
        #expect(visit.stage == stage)
        #expect(visit.confirmedByPatient == confirmed)
        #expect(visit.status.stage == stage)
    }

    @Test func `advancing walks the whole visit and tells the stream`() async throws {
        let id = StubClinicService.startingVisitId
        let service = StubClinicService(stage: .intake)
        var updates = await service.visitUpdates(visitId: id).makeAsyncIterator()
        #expect(await next(&updates) == .open)

        var stages: [VisitStage] = []
        var flags: [Bool] = []
        for _ in 0..<6 {
            try await service.advance(visitId: id)
            #expect(await next(&updates) == .changed)
            let visit = try await service.getVisit(visitId: id)
            stages.append(visit.stage)
            flags.append(visit.confirmedByPatient)
        }
        #expect(stages == [.intake, .reserved, .triage, .doctor, .pharmacy, .completed])
        #expect(flags == [true, true, true, true, true, true])

        await #expect(throws: ClinicError.self) { try await service.advance(visitId: id) }
    }

    @Test func `a dropped stream says so and ends`() async {
        let id = StubClinicService.startingVisitId
        let service = StubClinicService(stage: .triage)
        var updates = await service.visitUpdates(visitId: id).makeAsyncIterator()
        #expect(await next(&updates) == .open)
        await service.dropUpdates(visitId: id)
        #expect(await next(&updates) == .dropped)
        #expect(await next(&updates) == nil)
    }

    @Test func `the demo patient's visit, from chat to rating`() async throws {
        let service = StubClinicService()
        _ = try await service.authVerify(qid: "DEMO-10001", otp: "0000")
        let created = try await service.createVisit(patientId: nil)
        let id = created.visitId
        #expect(created.opening == "شو اللي يتعبك اليوم؟")

        var reply: ChatResponse?
        for text in ["حرارة", "٦", "بنادول", "لا"] {
            reply = try await service.sendChat(visitId: id, text: text)
        }
        #expect(reply?.done == true)
        #expect(try await service.getVisit(visitId: id).chat.messages.count == 9)

        #expect(try await service.confirmIntake(visitId: id, service: nil).service == .gp)
        let centres = try await service.listCentres(
            service: "gp", visitId: id, lat: nil, lng: nil)
        #expect(centres.defaultCentreId == "C-WAKRA")
        #expect(centres.centres.first?.registered == true)

        let reserved = try await service.reserve(visitId: id, centreId: "C-WAKRA")
        #expect(reserved.ticket.number == nil)
        #expect(reserved.message == "Check-in valid for 45 minutes")
        #expect(Timestamp.date(from: reserved.expiresAt) != nil)

        let arrived = try await service.arrive(visitId: id, body: .button)
        #expect(arrived.ticket.number == "T-014")
        #expect(arrived.goTo != nil)

        for _ in 0..<3 { try await service.advance(visitId: id) }
        #expect(try await service.getVisit(visitId: id).stage == .completed)
        #expect(try await service.rateVisit(visitId: id, stars: 5).rating == 5)
        await #expect(throws: ClinicError.self) {
            try await service.rateVisit(visitId: id, stars: 4)
        }
        let rows = try await service.listVisits()
        #expect(rows.map(\.visitId) == [id])
        #expect(rows.first?.active == false)
    }

    @Test func `Ravi's visit stops at emergency with no ticket`() async throws {
        let service = StubClinicService()
        _ = try await service.authVerify(qid: "DEMO-10003", otp: "0000")
        let id = try await service.createVisit(patientId: nil).visitId
        let reply = try await service.sendChat(visitId: id, text: "x")
        #expect(reply.emergency)
        #expect(reply.status == .redirectedEmergency)
        let override = try await service.emergencyOverride(visitId: id)
        #expect(override.ticket == nil)
        let visit = try await service.getVisit(visitId: id)
        #expect(visit.ticket == nil)
        #expect(gatedScreen(for: visit, requested: .chat) == .emergency)
    }

    @Test func `Ahmed's visit takes the refill route with no ticket`() async throws {
        let service = StubClinicService()
        _ = try await service.authVerify(qid: "DEMO-10002", otp: "0000")
        let id = try await service.createVisit(patientId: nil).visitId
        let reply = try await service.sendChat(visitId: id, text: "x")
        #expect(reply.refill?.medicine == "amlodipine 5 mg once daily")
        #expect(try await service.getVisit(visitId: id).ticket == nil)
        let moved = try await service.continueRefill(visitId: id)
        #expect(moved.service == .gp)
        #expect(gatedScreen(for: try await service.getVisit(visitId: id), requested: nil) == .centre)
    }

    @Test func `an unknown visit is a 404`() async {
        await #expect {
            try await StubClinicService().getVisit(visitId: "V-NOPE")
        } throws: { error in
            (error as? ClinicError)?.status == 404
        }
    }

    @Test func `screens get nothing before a login`() async {
        await #expect {
            try await StubClinicService().getMe()
        } throws: { error in
            (error as? ClinicError)?.code == "unauthorized"
        }
    }
}
