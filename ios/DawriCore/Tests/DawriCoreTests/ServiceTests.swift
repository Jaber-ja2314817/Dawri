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

/// What the app relies on from `LocalClinicService` and the contract suite does not pin:
/// exact seeded values through the protocol, and the core's navigation rules on real visits.
@Suite("LocalClinicService through the protocol")
struct LocalServiceTests {
    private func signedIn(_ qid: String) async throws -> any ClinicService {
        let service: any ClinicService = LocalClinicService(store: MemoryClinicStore())
        _ = try await service.authVerify(qid: qid, otp: "0000")
        return service
    }

    /// The backend lists every patient who is not a dependent, so the three lead the list and
    /// are not all of it. The login chips are the web's fixed three.
    @Test func `the demo patients start with the real three`() async {
        let patients = await LocalClinicService(store: MemoryClinicStore()).demoPatients()
        let three = patients.prefix(3)
        #expect(three.map(\.id) == ["P001", "P002", "P003"])
        #expect(three.map(\.qidDemo) == ["DEMO-10001", "DEMO-10002", "DEMO-10003"])
        #expect(three.map(\.fullNameEn) == ["Fatima Al-Demo", "Ahmed Al-Demo", "Ravi Demo"])
        #expect(three.map(\.fullNameAr) == ["فاطمة التجريبية", "أحمد التجريبي", "رافي"])
    }

    @Test func `Fatima chooses who the visit is for and Ravi goes to consent`() async throws {
        let service = try await signedIn("DEMO-10001")
        #expect(checkInRoute(try await service.getMe()) == .who)
        _ = try await service.authVerify(qid: "DEMO-10003", otp: "0000")
        #expect(checkInRoute(try await service.getMe()) == .consent(patientId: "P003"))
    }

    @Test func `the first question is the receptionist's own line`() async throws {
        let service = try await signedIn("DEMO-10001")
        #expect(try await service.createVisit(patientId: nil).opening == "شو اللي يتعبك اليوم؟")
    }

    @Test func `a finished visit is in history but no longer active`() async throws {
        let (service, visitId) = try await LocalClinicService.staged(stage: .completed)
        let rows = try await service.listVisits()
        #expect(rows.map(\.visitId) == [visitId])
        #expect(rows.first?.active == false)
    }

    @Test func `after an emergency the gate sends a request for chat to the emergency screen`() async throws {
        let service = try await signedIn("DEMO-10003")
        let visitId = try await service.createVisit(patientId: nil).visitId
        _ = try await service.sendChat(visitId: visitId, text: "Chest pain going to my left arm.")
        let visit = try await service.getVisit(visitId: visitId)
        #expect(gatedScreen(for: visit, requested: .chat) == .emergency)
    }

    @Test func `Ahmed's refill names his medicine, and carrying on opens the centres`() async throws {
        let service = try await signedIn("DEMO-10002")
        let visitId = try await service.createVisit(patientId: nil).visitId
        let reply = try await service.sendChat(
            visitId: visitId, text: "I need my usual blood pressure tablets.")
        #expect(reply.refill?.medicine == "amlodipine 5 mg once daily")
        _ = try await service.continueRefill(visitId: visitId)
        let visit = try await service.getVisit(visitId: visitId)
        #expect(gatedScreen(for: visit, requested: nil) == .centre)
    }

    /// The method `-demoConfirmed` uses for a flag no route can reach. Chat is offered for an
    /// open, unconfirmed intake and for nothing else, whichever way the flag points.
    @Test(arguments: VisitStage.allCases, [false, true])
    func `a saved confirmed flag reaches the visit at every stage`(
        stage: VisitStage, confirmed: Bool
    ) async throws {
        let store = MemoryClinicStore()
        let (_, visitId) = try await LocalClinicService.staged(
            patientId: stage == .refill ? "P002" : "P001",
            stage: stage == .cancelled && confirmed ? .intake : stage, confirmed: confirmed,
            store: store)
        var state = try #require(store.load())
        state.chats[visitId]?.confirmedByPatient = confirmed
        if stage == .cancelled {
            let row = try #require(state.clinic.visits.firstIndex { $0.id == visitId })
            state.clinic.visits[row].status = .cancelled
        }

        let rebuilt = LocalClinicService(store: try MemoryClinicStore(state: state))
        let visit = try await rebuilt.getVisit(visitId: visitId)
        #expect(visit.stage == stage)
        #expect(visit.confirmedByPatient == confirmed)
        #expect(visit.status.stage == stage)
        let offersChat = gatedScreen(for: visit, requested: .chat) == .chat
        #expect(offersChat == (stage == .intake && !confirmed))
    }
}
