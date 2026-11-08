import Foundation
import Testing
@testable import DawriCore

// The port of frontend/src/features/chat/ChatScreen.test.tsx and the S07 half of
// Screens.test.tsx. Each suite is a `describe` block and each display name is the web's `it`,
// word for word. Cases about the DOM alone (scrolling, focus, `dir="auto"`, the scripted note in
// real AI mode, the 16 kHz upload) are listed at the end of this file with where they are covered.

// MARK: - Fixtures, the port of fixtures.ts

enum ChatFixture {
    static let id = "V1"

    static let intake = Intake(
        emergency: false, language: "ar-gulf",
        chiefComplaintPatientWords: "عندي حرارة وكحة من ثلاث أيام", severity0To10: 6,
        selfMedication: ["paracetamol"], service: .gp, serviceConfidence: 0.8,
        refillRequest: nil, questionsAsked: 5, deniedRedFlags: [])

    static let opening = ChatMessage(role: .assistant, content: "شو اللي يتعبك اليوم؟", slot: "complaint")

    static let summaryText =
        "شكرا. هذا اللي بقوله للممرضة: حرارة وكحة، 3 أيام، الشدة 6 من 10. هل هذا صحيح؟"

    static let summaryMessage = ChatMessage(role: .assistant, content: summaryText, slot: "summary")

    static let question = "كم شدته من 0 إلى 10؟"

    static func visit(
        messages: [ChatMessage] = [opening], intake: Intake? = nil, status: VisitStatus = .intake,
        confirmed: Bool = false, refill: String? = nil
    ) -> Visit {
        Visit(
            visitId: id, patientId: "P1", bookedBy: "P1", status: status, stage: status.stage,
            service: nil, createdAt: "2026-11-06T10:00:00Z", arrivedAt: nil, completedAt: nil,
            centre: nil, ticket: nil, intake: intake, confirmedByPatient: confirmed,
            chat: VisitChat(messages: messages, language: "ar"),
            medicines: VisitMedicines(en: [], ar: []), emergency: nil, goTo: nil,
            refill: refill.map(RefillMedicine.init(medicine:)), rating: nil)
    }

    static let atSummary = visit(messages: [opening, summaryMessage], intake: intake)

    static func turn(
        reply: String = question, done: Bool = false, emergency: Bool = false,
        intake: Intake? = nil, refill: String? = nil, status: VisitStatus = .intake
    ) -> ChatResponse {
        ChatResponse(
            reply: reply, done: done, emergency: emergency, intake: intake,
            refill: refill.map(RefillMedicine.init(medicine:)), denied: [], aiSource: "simulated",
            selfHarm: false, status: status, transcript: nil, nearestEd: nil)
    }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, content: text, slot: nil)
    }

    static let down = ClinicError.network
}

// MARK: - Fakes

/// A request the test answers when it chooses. Polls, so a cancelled request ends the way the
/// web's aborted fetch does, with an error.
@MainActor
final class Held<T: Sendable> {
    private var result: Result<T, any Error>?
    private(set) var cancelled = false

    func value() async throws -> T {
        while result == nil {
            do {
                try await Task.sleep(for: .milliseconds(2))
            } catch {
                cancelled = true
                throw error
            }
        }
        return try result!.get()
    }

    func resolve(_ value: T) { result = .success(value) }
    func reject(_ error: any Error) { result = .failure(error) }
}

/// The clinic the chat talks to. Every call is logged in order, so a test can say what was asked
/// and when.
@MainActor
final class FakeClinic: ClinicService {
    private(set) var calls: [String] = []
    var sendChatHandler: @MainActor (String) async throws -> ChatResponse = { _ in ChatFixture.turn() }
    var getVisitHandler: @MainActor () async throws -> Visit = { ChatFixture.visit() }
    var confirmHandler: @MainActor () async throws -> ConfirmResponse = {
        ConfirmResponse(status: .intake, service: .gp, intake: ChatFixture.intake)
    }
    var continueRefillHandler: @MainActor () async throws -> ConfirmResponse = {
        ConfirmResponse(status: .intake, service: .gp, intake: nil)
    }

    func count(_ route: String) -> Int {
        calls.count { $0 == route || $0.hasPrefix("\(route) ") }
    }

    private func unexpected(_ route: String) -> ClinicError {
        calls.append(route)
        return ClinicError(status: 500, code: "unexpected", message: route)
    }

    func sendChat(visitId: String, text: String) async throws -> ChatResponse {
        calls.append("sendChat \(text)")
        return try await sendChatHandler(text)
    }

    func getVisit(visitId: String) async throws -> Visit {
        calls.append("getVisit")
        return try await getVisitHandler()
    }

    func confirmIntake(visitId: String, service: Service?) async throws -> ConfirmResponse {
        calls.append("confirmIntake \(service?.rawValue ?? "{}")")
        return try await confirmHandler()
    }

    func continueRefill(visitId: String) async throws -> ConfirmResponse {
        calls.append("continueRefill \(visitId)")
        return try await continueRefillHandler()
    }

    func authStart(qid: String) async throws -> AuthStartResponse { throw unexpected("authStart") }
    func authVerify(qid: String, otp: String) async throws -> Patient { throw unexpected("authVerify") }
    func demoPatients() async throws -> [DemoPatient] { throw unexpected("demoPatients") }
    func health() async throws -> Health { throw unexpected("health") }
    func getMe() async throws -> Me { throw unexpected("getMe") }
    func createVisit(patientId: String?) async throws -> CreateVisitResponse { throw unexpected("createVisit") }
    func listVisits() async throws -> [VisitRow] { throw unexpected("listVisits") }
    func emergencyOverride(visitId: String) async throws -> OverrideResponse { throw unexpected("emergencyOverride") }
    func listCentres(service: String, visitId: String, lat: Double?, lng: Double?) async throws -> CentreList {
        throw unexpected("listCentres")
    }
    func reserve(visitId: String, centreId: String) async throws -> ReserveResponse { throw unexpected("reserve") }
    func arrive(visitId: String, body: ArriveBody) async throws -> ArriveResponse { throw unexpected("arrive") }
    func rateVisit(visitId: String, stars: Int) async throws -> RatingResponse { throw unexpected("rateVisit") }
    var isSignedIn: Bool { get async { true } }
    func signOut() async {}
    func visitUpdates(visitId: String) async -> AsyncStream<VisitUpdate> { AsyncStream { $0.finish() } }
}

/// The 45 s limit's clock, which only runs out when the test says so.
@MainActor
final class LimitClock {
    private(set) var requested: [Duration] = []
    /// How many of the waits so far have run out. A wait that starts later is a new 45 s.
    private var ranOut = 0

    nonisolated func sleep(_ duration: Duration) async throws {
        let index = await record(duration)
        while await !hasRunOut(index) {
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func record(_ duration: Duration) -> Int {
        requested.append(duration)
        return requested.count - 1
    }

    private func hasRunOut(_ index: Int) -> Bool { index < ranOut }

    /// Every wait now running reaches its limit.
    func runOut() { ranOut = requested.count }
}

/// The chat with the app around it: who is signed in, the routes it takes, and the gate's
/// refetch, which reads `gateVisit`.
@MainActor
final class ChatRig {
    let clinic = FakeClinic()
    let clock = LimitClock()
    var token: String? = "fatima"
    private(set) var routed: [String] = []
    /// What the clinic had been asked when the emergency route ran.
    private(set) var callsAtEmergency: [String]?
    private(set) var refetches = 0
    var gateVisit: Visit?
    private(set) var chat: ChatModel!

    init(_ visit: Visit = ChatFixture.visit(), attached: Bool = true) {
        let clock = self.clock
        chat = ChatModel(
            service: clinic, visit: visit,
            routes: ChatModel.Routes(
                emergency: { [unowned self] in
                    routed.append("emergency")
                    callsAtEmergency = clinic.calls
                },
                refill: { [unowned self] in routed.append("refill") },
                movedOn: { [unowned self] in routed.append("centre") }),
            session: { [unowned self] in token },
            sleep: { try await clock.sleep($0) })
        if attached { attach() }
    }

    func attach() {
        chat.attach { [unowned self] in
            refetches += 1
            return gateVisit
        }
    }

    /// The patient types and taps Send. The send runs on, as a tap's task does.
    @discardableResult
    func typeAndSend(_ text: String) -> Task<Void, Never> {
        chat.setDraft(text)
        return Task { await chat.submit() }
    }
}

/// Waits for what a task in flight will do. Generous, because the golden suites can hold the
/// machine for seconds when everything runs in parallel.
@MainActor
func eventually(
    _ what: Comment = "", timeout: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation, _ condition: () -> Bool
) async {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("Timed out waiting. \(what)", sourceLocation: sourceLocation)
            return
        }
        try? await Task.sleep(for: .milliseconds(2))
    }
}

private func text(_ key: String, _ lang: Lang) -> String {
    Strings.bundled.translate(lang, key)
}

// MARK: - ChatScreen.test.tsx

@MainActor
@Suite("Patient: chat", .timeLimit(.minutes(1)))
struct ChatModelTests {
    @MainActor
    @Suite("the conversation")
    struct Conversation {
        @Test("shows role and content only, each bubble finding its own direction")
        func roleAndContent() {
            // The direction half is `Bidi.auto` in ChatBubble, which this suite cannot see.
            let rig = ChatRig(ChatFixture.visit(messages: [ChatFixture.opening, ChatFixture.user("٦")]))
            #expect(rig.chat.messages.map(\.content) == ["شو اللي يتعبك اليوم؟", "٦"])
            #expect(rig.chat.messages.map(\.role) == [.assistant, .user])
        }

        @Test("never reads a nurse summary, even if one arrived")
        func noNurseSummary() throws {
            var json = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(ChatFixture.atSummary)) as! [String: Any]
            var intake = json["intake"] as! [String: Any]
            intake["summary_for_nurse"] = "NURSE ONLY"
            json["intake"] = intake
            let leaked = try JSONDecoder().decode(
                Visit.self, from: JSONSerialization.data(withJSONObject: json))
            let rig = ChatRig(leaked)
            let shown = rig.chat.messages.map(\.content) + [rig.chat.summary?.text ?? ""]
            #expect(!shown.joined().contains("NURSE ONLY"))
            #expect(!String(describing: rig.chat.summary as Any).contains("NURSE ONLY"))
        }

        @Test("shows the reply and keeps it after the visit catches up")
        func replyKept() async {
            let rig = ChatRig()
            await rig.typeAndSend("عندي حرارة وكحة من ثلاث أيام").value
            #expect(rig.chat.messages.last?.content == ChatFixture.question)
            #expect(rig.refetches == 1)
            rig.chat.sync(ChatFixture.visit(messages: [
                ChatFixture.opening, ChatFixture.user("عندي حرارة وكحة من ثلاث أيام"),
                ChatMessage(role: .assistant, content: ChatFixture.question, slot: "severity"),
            ]))
            #expect(rig.chat.messages.count == 3)
        }

        @Test("sends one message at a time and says it is thinking")
        func oneAtATime() async {
            let rig = ChatRig()
            let reply = Held<ChatResponse>()
            rig.clinic.sendChatHandler = { _ in try await reply.value() }
            let first = rig.typeAndSend("one")
            await eventually { rig.clinic.count("sendChat") == 1 }
            #expect(rig.chat.thinking)
            #expect(text("chat.thinking", .ar) == "لحظة من فضلك…")
            rig.chat.setDraft("two")
            await rig.chat.submit()
            #expect(rig.clinic.count("sendChat") == 1)
            reply.resolve(ChatFixture.turn())
            await first.value
            #expect(!rig.chat.thinking)
        }

        @Test("limits the box to 2000 characters")
        func limit() {
            let rig = ChatRig()
            rig.chat.setDraft(String(repeating: "ب", count: 2500))
            #expect(rig.chat.draft.utf16.count == 2000)
            #expect(ChatRules.maxText == 2000)
            // A pair is never split at the limit.
            rig.chat.setDraft(String(repeating: "a", count: 1999) + "😀")
            #expect(rig.chat.draft == String(repeating: "a", count: 1999))
        }
    }

    @MainActor
    @Suite("outcomes")
    struct Outcomes {
        @Test("goes straight to the emergency screen and shows no question")
        func emergency() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in
                ChatFixture.turn(reply: "NOT TO BE SHOWN", emergency: true, status: .redirectedEmergency)
            }
            await rig.typeAndSend("Chest pain going to my left arm.").value
            #expect(rig.routed == ["emergency"])
            #expect(!rig.chat.messages.contains { $0.content == "NOT TO BE SHOWN" })
            // No second request, before the route or after it.
            #expect(rig.callsAtEmergency == ["sendChat Chest pain going to my left arm."])
            #expect(rig.clinic.calls == ["sendChat Chest pain going to my left arm."])
            #expect(rig.refetches == 0)
        }

        @Test("puts an emergency ahead of everything else in the response")
        func emergencyFirst() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in
                ChatFixture.turn(emergency: true, intake: ChatFixture.intake, refill: "x").withDone()
            }
            await rig.typeAndSend("text").value
            #expect(rig.routed == ["emergency"])
            #expect(rig.chat.summary == nil)
            #expect(rig.callsAtEmergency == ["sendChat text"])
            #expect(rig.refetches == 0)
        }

        @Test("goes to the refill screen")
        func refill() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in ChatFixture.turn(refill: "amlodipine 5 mg once daily") }
            await rig.typeAndSend("I need my usual blood pressure tablets.").value
            #expect(rig.routed == ["refill"])
        }
    }

    @MainActor
    @Suite("the summary")
    struct Summary {
        @Test("appears from done")
        func fromDone() async throws {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in
                ChatFixture.turn(reply: ChatFixture.summaryText, done: true, intake: ChatFixture.intake)
            }
            await rig.typeAndSend("لا شي").value
            let summary = try #require(rig.chat.summary)
            #expect(summary.text.contains("حرارة وكحة"))
            #expect(text("chat.service.\(summary.service.rawValue)", .ar) == "طب عام")
            // The card asks once, in its own heading, so the read-back loses its question.
            let shown = ChatRules.withoutClosingQuestion(summary.text)
            #expect(!shown.contains("هل هذا صحيح؟"))
            #expect(text("chat.summary.check", .ar) == "هل هذا صحيح؟")
            // Its bubble is the one the card replaces.
            #expect(rig.chat.messages[summary.index].content == ChatFixture.summaryText)
        }

        @Test("appears from reload data")
        func fromReload() {
            let rig = ChatRig(ChatFixture.atSummary)
            #expect(rig.chat.summary?.text.contains("الشدة 6 من 10") == true)
        }

        @Test("stays away while the last message is a question")
        func awayForQuestion() {
            let question = ChatMessage(role: .assistant, content: "من متى؟", slot: nil)
            let rig = ChatRig(ChatFixture.visit(
                messages: [ChatFixture.opening, ChatFixture.summaryMessage, ChatFixture.user("و"), question],
                intake: ChatFixture.intake))
            #expect(rig.chat.summary == nil)
        }

        @Test("names the service in the screen language")
        func serviceName() throws {
            var intake = ChatFixture.intake
            intake.service = .dental
            let rig = ChatRig(ChatFixture.visit(
                messages: [ChatFixture.opening, ChatFixture.summaryMessage], intake: intake))
            let summary = try #require(rig.chat.summary)
            #expect(text("chat.service.\(summary.service.rawValue)", .ar).contains("الأسنان"))
        }

        @Test("confirms and goes to the centre")
        func confirms() async {
            let rig = ChatRig(ChatFixture.atSummary)
            await rig.chat.confirm(unsentWords: false)
            #expect(rig.routed == ["centre"])
            #expect(rig.clinic.calls == ["confirmIntake {}"])
        }

        @Test("shows a failed confirm in place")
        func failedConfirm() async throws {
            let rig = ChatRig(ChatFixture.atSummary)
            rig.clinic.confirmHandler = { throw ChatFixture.down }
            await rig.chat.confirm(unsentWords: false)
            let error = try #require(rig.chat.confirmError)
            #expect(errorText(error, strings: .bundled, lang: .ar).contains("تعذر الوصول"))
            #expect(rig.chat.summary != nil)
            #expect(!rig.chat.confirming)
            #expect(rig.routed.isEmpty)
        }

        @Test("focuses the box to change something, and the correction is a normal message")
        func correction() async throws {
            // Focus is the screen's. The correction is an ordinary send.
            let rig = ChatRig(ChatFixture.atSummary)
            rig.clinic.sendChatHandler = { _ in
                ChatFixture.turn(reply: "شكرا. ملخص جديد. هل هذا صحيح؟", done: true, intake: ChatFixture.intake)
            }
            await rig.typeAndSend("وعندي صداع بعد").value
            #expect(rig.clinic.calls == ["sendChat وعندي صداع بعد"])
            #expect(try #require(rig.chat.summary).text.contains("ملخص جديد"))
        }
    }

    @MainActor
    @Suite("words not yet sent at the summary")
    struct Unsent {
        private func unsent(_ chat: ChatModel, _ voice: VoiceModel? = nil) -> Bool {
            ChatRules.hasUnsentWords(
                draft: chat.draft, voiceStep: voice?.step ?? .idle, transcript: voice?.transcript ?? "")
        }

        @Test("offers Yes while nothing waits to be sent")
        func offersYes() {
            let rig = ChatRig(ChatFixture.atSummary)
            #expect(!unsent(rig.chat))
        }

        @Test("holds Yes while the box has text, and says what to do")
        func holdsForBox() async {
            let rig = ChatRig(ChatFixture.atSummary)
            rig.chat.setDraft("chest pain")
            #expect(unsent(rig.chat))
            #expect(text("chat.summary.unsent", .ar) == "أرسل رسالتك أو امسحها أولاً.")
            await rig.chat.confirm(unsentWords: unsent(rig.chat))
            #expect(rig.clinic.count("confirmIntake") == 0)
        }

        @Test("says it in English too")
        func english() {
            #expect(text("chat.summary.unsent", .en) == "Send or clear your message first.")
        }

        @Test("gives Yes back when the box is emptied, and does not count spaces as words")
        func emptied() {
            let rig = ChatRig(ChatFixture.atSummary)
            rig.chat.setDraft("chest pain")
            rig.chat.setDraft("")
            #expect(!unsent(rig.chat))
            rig.chat.setDraft("   ")
            #expect(!unsent(rig.chat))
        }

        @Test("reaches the emergency screen through Send, having confirmed nothing")
        func emergencyThroughSend() async {
            let rig = ChatRig(ChatFixture.atSummary)
            rig.clinic.sendChatHandler = { _ in ChatFixture.turn(emergency: true, status: .redirectedEmergency) }
            await rig.typeAndSend("chest pain").value
            #expect(rig.routed == ["emergency"])
            #expect(rig.clinic.calls == ["sendChat chest pain"])
            #expect(rig.clinic.count("confirmIntake") == 0)
        }

        @Test("holds Yes on a transcript waiting to be sent, and Clear gives it back")
        func transcriptHolds() async {
            let rig = ChatRig(ChatFixture.atSummary)
            let voice = VoiceRig(heard: "ألم في الصدر")
            await voice.record()
            #expect(voice.model.step == .confirm)
            #expect(unsent(rig.chat, voice.model))
            voice.model.reset()
            #expect(voice.model.transcript.isEmpty)
            #expect(!unsent(rig.chat, voice.model))
            #expect(rig.clinic.count("sendChat") == 0)
        }

        @Test("gives Yes back when the transcript step is emptied by hand")
        func transcriptEmptied() async {
            let rig = ChatRig(ChatFixture.atSummary)
            let voice = VoiceRig(heard: "ألم في الصدر")
            await voice.record()
            voice.model.setTranscript(" ")
            #expect(!unsent(rig.chat, voice.model))
        }

        @Test("holds Yes for the words a recording is about to bring")
        func recordingHolds() async {
            let rig = ChatRig(ChatFixture.atSummary)
            let voice = VoiceRig()
            await voice.model.start()
            #expect(voice.model.step == .listening)
            #expect(unsent(rig.chat, voice.model))
            // And before the microphone has even opened.
            #expect(ChatRules.hasUnsentWords(draft: "", voiceStep: .starting, transcript: ""))
            #expect(ChatRules.hasUnsentWords(draft: "", voiceStep: .transcribing, transcript: ""))
        }

        @Test("keeps a failed Yes from going round the hold through its Retry")
        func failedYesHeld() async {
            let rig = ChatRig(ChatFixture.atSummary)
            rig.clinic.confirmHandler = { throw ChatFixture.down }
            await rig.chat.confirm(unsentWords: unsent(rig.chat))
            #expect(rig.chat.confirmError != nil)
            #expect(rig.clinic.count("confirmIntake") == 1)
            rig.chat.setDraft("chest pain")
            // The card's Retry is the same call, and it holds the same way.
            await rig.chat.confirm(unsentWords: unsent(rig.chat))
            #expect(rig.clinic.count("confirmIntake") == 1)
        }
    }

    @MainActor
    @Suite("leaving chat with a turn in flight")
    struct Leaving {
        enum Answer: String, CaseIterable, Sendable {
            case question, refill, summary

            var response: ChatResponse {
                switch self {
                case .question: ChatFixture.turn()
                case .refill: ChatFixture.turn(refill: "x")
                case .summary: ChatFixture.turn(intake: ChatFixture.intake).withDone()
                }
            }
        }

        private func held(_ rig: ChatRig) -> Held<ChatResponse> {
            let reply = Held<ChatResponse>()
            rig.clinic.sendChatHandler = { _ in try await reply.value() }
            return reply
        }

        @Test("goes to the emergency screen when the red flag lands, wherever the patient went")
        func redFlagAfterLeaving() async {
            let rig = ChatRig()
            let reply = held(rig)
            let send = rig.typeAndSend("chest pain")
            await eventually { rig.clinic.count("sendChat") == 1 }
            rig.chat.detach()
            reply.resolve(ChatFixture.turn(emergency: true))
            await send.value
            #expect(rig.routed == ["emergency"])
            #expect(rig.callsAtEmergency == ["sendChat chest pain"])
        }

        @Test("leaves the request running, so the reply can land at all")
        func requestRuns() async {
            let rig = ChatRig()
            let reply = held(rig)
            let send = rig.typeAndSend("chest pain")
            await eventually { rig.clinic.count("sendChat") == 1 }
            rig.chat.detach()
            try? await Task.sleep(for: .milliseconds(20))
            #expect(!reply.cancelled)
            reply.resolve(ChatFixture.turn(emergency: true))
            await send.value
            #expect(!reply.cancelled)
            #expect(rig.routed == ["emergency"])
        }

        @Test("moves nobody for %s", arguments: Answer.allCases)
        func movesNobody(_ answer: Answer) async {
            let rig = ChatRig()
            let reply = held(rig)
            let send = rig.typeAndSend("hello")
            await eventually { rig.clinic.count("sendChat") == 1 }
            rig.chat.detach()
            reply.resolve(answer.response)
            await send.value
            #expect(rig.routed.isEmpty)
            #expect(rig.refetches == 0)
            // Here the model outlives the screen, so it is not left thinking for the return.
            #expect(!rig.chat.thinking)
        }

        @Test("moves nobody who signed out, or signed in as someone else")
        func otherSession() async {
            for next in [nil, "ravi"] as [String?] {
                let rig = ChatRig()
                let reply = held(rig)
                let send = rig.typeAndSend("chest pain")
                await eventually { rig.clinic.count("sendChat") == 1 }
                rig.chat.detach()
                rig.token = next
                reply.resolve(ChatFixture.turn(emergency: true))
                await send.value
                #expect(rig.routed.isEmpty, "signed in as \(next ?? "nobody")")
            }
        }

        @Test("asks the visit when the turn fails after leaving")
        func asksTheVisit() async {
            let rig = ChatRig()
            let reply = held(rig)
            rig.clinic.getVisitHandler = { ChatFixture.visit(status: .redirectedEmergency) }
            let send = rig.typeAndSend("chest pain")
            await eventually { rig.clinic.count("sendChat") == 1 }
            rig.chat.detach()
            reply.reject(ChatFixture.down)
            await send.value
            #expect(rig.routed == ["emergency"])
            #expect(rig.clinic.count("getVisit") >= 1)
        }

        @Test("stays put when the failed turn was no emergency")
        func staysPut() async {
            let rig = ChatRig()
            let reply = held(rig)
            rig.clinic.getVisitHandler = { ChatFixture.visit() }
            let send = rig.typeAndSend("hello")
            await eventually { rig.clinic.count("sendChat") == 1 }
            rig.chat.detach()
            reply.reject(ChatFixture.down)
            await send.value
            #expect(rig.clinic.count("getVisit") >= 1)
            #expect(rig.routed.isEmpty)
            // The words wait in the box for the patient's return, with a Retry that looks first.
            #expect(rig.chat.draft == "hello")
            #expect(rig.chat.failure?.retry == true)
        }
    }

    @MainActor
    @Suite("error-retry")
    struct ErrorRetry {
        @Test("keeps the words and offers Retry when the message did not land")
        func keepsWords() async throws {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = { ChatFixture.visit() }
            await rig.typeAndSend("عندي حرارة").value
            let failure = try #require(rig.chat.failure)
            #expect(failure.retry)
            #expect(!failure.timedOut)
            #expect(rig.chat.draft == "عندي حرارة")
            #expect(rig.chat.messages.map(\.content) == [ChatFixture.opening.content])
            #expect(rig.clinic.count("sendChat") == 1)

            rig.clinic.sendChatHandler = { _ in ChatFixture.turn() }
            await rig.chat.retry()
            #expect(rig.chat.messages.last?.content == ChatFixture.question)
            #expect(rig.clinic.count("sendChat") == 2)
            #expect(rig.chat.draft.isEmpty)
            #expect(rig.chat.failure == nil)
        }

        @Test("does not resend what the server already stored")
        func noResend() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = {
                ChatFixture.visit(messages: [
                    ChatFixture.opening, ChatFixture.user("عندي حرارة"),
                    ChatMessage(role: .assistant, content: "من متى؟", slot: "duration"),
                ])
            }
            await rig.typeAndSend("عندي حرارة").value
            #expect(rig.refetches == 1)
            #expect(rig.chat.failure == nil)
            #expect(rig.clinic.count("sendChat") == 1)
            #expect(rig.chat.draft.isEmpty)
        }

        @Test("tells an old \"no\" from a new one")
        func oldNo() async {
            let earlier = [
                ChatFixture.opening, ChatFixture.user("لا"),
                ChatMessage(role: .assistant, content: "من متى؟", slot: "duration"),
            ]
            let rig = ChatRig(ChatFixture.visit(messages: earlier))
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = { ChatFixture.visit(messages: earlier) }
            await rig.typeAndSend("لا").value
            #expect(rig.chat.failure?.retry == true)
            #expect(rig.chat.draft == "لا")
        }

        @Test("looks again before a retry, and never sends blind")
        func looksBeforeRetry() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = { throw ChatFixture.down }
            await rig.typeAndSend("عندي حرارة").value
            #expect(rig.chat.failure != nil)

            await rig.chat.retry()
            #expect(rig.clinic.count("getVisit") == 3)
            #expect(rig.chat.failure?.retry == true)
            #expect(rig.clinic.count("sendChat") == 1)
            // The look comes first: no send between the two reads of the retry.
            #expect(rig.clinic.calls == [
                "sendChat عندي حرارة", "getVisit", "getVisit", "getVisit",
            ])
        }

        @Test("gives up after 45 s and keeps the words")
        func timeout() async throws {
            let rig = ChatRig()
            let reply = Held<ChatResponse>()
            rig.clinic.sendChatHandler = { _ in try await reply.value() }
            rig.clinic.getVisitHandler = { ChatFixture.visit() }
            let send = rig.typeAndSend("عندي حرارة")
            await eventually { rig.clock.requested.count == 1 }
            #expect(rig.clock.requested == [.seconds(45)])
            try? await Task.sleep(for: .milliseconds(20))
            #expect(rig.chat.failure == nil)
            #expect(rig.chat.thinking)

            rig.clock.runOut()
            await send.value
            let failure = try #require(rig.chat.failure)
            #expect(failure.timedOut)
            #expect(failure.retry)
            await eventually("the limit ends the request") { reply.cancelled }
            #expect(text("chat.timeout", .ar).contains("تأخر الرد"))
            #expect(rig.chat.draft == "عندي حرارة")
        }

        @Test("refetches on 409 so the gate can move the patient")
        func refetchOn409() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in
                throw ClinicError(status: 409, code: "visit_not_in_intake", message: "This visit is past the chat stage.")
            }
            await rig.typeAndSend("text").value
            #expect(rig.refetches == 1)
            #expect(rig.clinic.count("getVisit") == 0)
            #expect(rig.chat.failure?.retry == false)
        }
    }

    @MainActor
    @Suite("voice")
    struct Voice {
        @Test("sends nothing until the patient confirms the transcript")
        func confirmFirst() async {
            let rig = ChatRig()
            let voice = VoiceRig(heard: "عندي حرارة وكحة من ثلاث أيام")
            await voice.record()
            #expect(voice.model.transcript == "عندي حرارة وكحة من ثلاث أيام")
            #expect(text("voice.confirm.check", .ar) == "هل هذا صحيح؟")
            #expect(rig.clinic.calls.isEmpty)

            voice.model.setTranscript("عندي حرارة")
            #expect(rig.clinic.calls.isEmpty)
            await rig.chat.sendText(voice.model.transcript)
            voice.model.reset()
            #expect(rig.clinic.calls == ["sendChat عندي حرارة"])
            #expect(rig.chat.messages.last?.content == ChatFixture.question)
        }

        @Test("uploads 16 kHz mono wav, whatever the browser recorded")
        func noUpload() async {
            // Replaced on the phone: there is no upload. Recording reaches no route at all.
            let rig = ChatRig()
            let voice = VoiceRig(heard: "hello")
            await voice.record()
            #expect(voice.model.step == .confirm)
            #expect(rig.clinic.calls.isEmpty)
        }

        @Test("records again on Try again, with nothing sent")
        func tryAgain() async {
            let rig = ChatRig()
            let voice = VoiceRig(heard: "wrong words")
            await voice.record()
            await voice.model.start()
            #expect(voice.model.step == .listening)
            #expect(voice.engine.started.count == 2)
            #expect(rig.clinic.calls.isEmpty)
        }

        @Test("shows message_ar on a 503, with no transcript, and focuses the box")
        func unavailable() async {
            // The phone's own line in place of the server's. Focus is the screen's.
            let rig = ChatRig()
            rig.chat.setDraft("كتبت شيئاً")
            let voice = VoiceModel(engine: UnavailableVoiceEngine(), language: .ar)
            await voice.start()
            #expect(voice.error == .unavailable)
            #expect(text(voice.error!.textKey, .ar) == "الصوت غير متاح على هذا الهاتف. يرجى كتابة رسالتك.")
            #expect(voice.transcript.isEmpty)
            #expect(voice.step == .idle)
            #expect(rig.clinic.calls.isEmpty)
            #expect(rig.chat.draft == "كتبت شيئاً")
        }

        @Test("tells the patient to type after %s", arguments: [
            ("no network", VoiceFailure.failed), ("a blank answer", VoiceFailure.blank),
        ])
        func typeAfter(_ name: String, _ failure: VoiceFailure) async {
            let voice = VoiceRig(heard: failure == .blank ? "   " : nil, stopFailure: failure)
            await voice.record()
            #expect(voice.model.error != nil, "\(name)")
            #expect(text(voice.model.error!.textKey, .ar).contains("يرجى كتابة رسالتك"))
            #expect(voice.model.transcript.isEmpty)
        }

        @Test("tells the patient to type when the microphone is %s", arguments: [
            ("blocked", VoiceFailure.denied, "لا يوجد إذن لاستخدام الميكروفون"),
            ("missing", VoiceFailure.unsupported, "التسجيل الصوتي لا يعمل على هذا الجهاز"),
        ])
        func microphone(_ name: String, _ failure: VoiceFailure, _ line: String) async {
            let voice = VoiceRig(startFailure: failure)
            await voice.model.start()
            #expect(voice.model.error == failure, "\(name)")
            #expect(text(voice.model.error!.textKey, .ar).contains(line))
        }

        @Test("tells the patient to type when the recording cannot be decoded")
        func decode() async {
            let voice = VoiceRig(stopFailure: .decode)
            await voice.record()
            #expect(text(voice.model.error!.textKey, .ar).contains("تعذرت قراءة"))
        }

        @Test("shows the timer while listening")
        func timer() async {
            let voice = VoiceRig()
            await voice.model.start()
            #expect(ChatRules.clock(voice.model.seconds) == "0:00")
        }

        @Test("moves on by itself when the recording ends at the cap")
        func cap() async {
            let voice = VoiceRig(heard: "heard")
            await voice.model.start()
            voice.engine.sessions.last?.endByItself()
            await eventually { voice.model.step == .confirm }
            #expect(voice.model.transcript == "heard")
        }

        @Test("stops the recording when the patient leaves")
        func stopsOnLeave() async {
            let voice = VoiceRig()
            await voice.model.start()
            await voice.model.leave()
            #expect(voice.engine.sessions.last?.cancelled == true)
            #expect(voice.model.step == .idle)
        }
    }

    // MARK: Rules a case above leans on, and the iOS-only rules of the brief

    @MainActor
    @Suite("the rules of send.ts")
    struct Rules {
        @Test func `an abort, a dropped network and a 5xx have unknown outcomes`() {
            #expect(ChatRules.isUnknownOutcome(CancellationError()))
            #expect(ChatRules.isUnknownOutcome(ClinicError.network))
            #expect(ChatRules.isUnknownOutcome(ClinicError(status: 500, code: "internal_error", message: "x")))
            #expect(ChatRules.isUnknownOutcome(ClinicError(status: 503, code: "x", message: "x")))
            #expect(!ChatRules.isUnknownOutcome(ClinicError(status: 409, code: "visit_not_in_intake", message: "x")))
            #expect(!ChatRules.isUnknownOutcome(ClinicError(status: 422, code: "invalid_text", message: "x")))
            #expect(!ChatRules.isUnknownOutcome(VoiceFailure.failed))
        }

        @Test func `stored means past the baseline only`() {
            let said = [ChatFixture.opening, ChatFixture.user("لا")]
            #expect(!ChatRules.isStored(said, baseline: 2, text: "لا"))
            #expect(ChatRules.isStored(said, baseline: 1, text: "لا"))
            #expect(!ChatRules.isStored(said + [ChatMessage(role: .assistant, content: "لا", slot: nil)], baseline: 2, text: "لا"))
        }

        @Test func `the closing question goes, and only the two exact endings`() {
            #expect(ChatRules.withoutClosingQuestion("Fever, 3 days. Is this right?") == "Fever, 3 days.")
            #expect(ChatRules.withoutClosingQuestion("حرارة. هل هذا صحيح؟  ") == "حرارة.")
            #expect(ChatRules.withoutClosingQuestion("Is this right? Fever.") == "Is this right? Fever.")
            #expect(ChatRules.withoutClosingQuestion("Fever. Is this correct?") == "Fever. Is this correct?")
            #expect(ChatRules.withoutClosingQuestion("Fever. is this right?") == "Fever. is this right?")
        }

        @Test func `the clock reads minutes and two-digit seconds`() {
            #expect(ChatRules.clock(0) == "0:00")
            #expect(ChatRules.clock(12) == "0:12")
            #expect(ChatRules.clock(61) == "1:01")
            #expect(ChatRules.clock(600) == "10:00")
        }

        @Test func `the turn limit is 45 seconds and the summary slot is the backend's`() {
            #expect(ChatRules.turnTimeout == .seconds(45))
            #expect(ChatRules.summarySlot == "summary")
        }

        @Test func `a message goes to the engine unaltered, with only the isolates taken out`() async {
            let rig = ChatRig()
            await rig.typeAndSend("  \u{2068}عندي ألم في الصدر\u{2069} 6/10\n").value
            #expect(rig.clinic.calls == ["sendChat عندي ألم في الصدر 6/10"])
            #expect(ChatRules.outgoing("\u{2066}T-014\u{2069}") == "T-014")
            #expect(ChatRules.outgoing("\u{200F}x") == "\u{200F}x")
        }

        @Test func `a blank box sends nothing`() async {
            let rig = ChatRig()
            await rig.typeAndSend("  \n ").value
            await rig.typeAndSend("\u{2068}\u{2069}").value
            #expect(rig.clinic.calls.isEmpty)
            #expect(!rig.chat.thinking)
        }

        @Test func `a transcript send leaves the box alone`() async {
            let rig = ChatRig()
            rig.chat.setDraft("typed first")
            await rig.chat.sendText("ألم في الصدر")
            #expect(rig.clinic.calls == ["sendChat ألم في الصدر"])
            #expect(rig.chat.draft == "typed first")
        }

        @Test func `a failed transcript send keeps what was typed, and fills an empty box`() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ClinicError(status: 422, code: "invalid_text", message: "x") }
            rig.chat.setDraft("typed first")
            await rig.chat.sendText("heard")
            #expect(rig.chat.draft == "typed first")
            rig.chat.setDraft("")
            await rig.chat.sendText("heard")
            #expect(rig.chat.draft == "heard")
            #expect(rig.chat.failure?.retry == false)
        }

        @Test func `a retry sends the edited words from the box`() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = { ChatFixture.visit() }
            await rig.typeAndSend("عندي حراره").value
            rig.clinic.sendChatHandler = { _ in ChatFixture.turn() }
            rig.chat.setDraft("عندي حرارة")
            await rig.chat.retry()
            #expect(rig.clinic.calls.last == "sendChat عندي حرارة")
            // New words are a new turn: nothing to look for first.
            #expect(rig.clinic.calls == ["sendChat عندي حراره", "getVisit", "sendChat عندي حرارة"])
        }

        @Test func `a retry of the same words looks first and sends once more only if they did not land`() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = { ChatFixture.visit() }
            await rig.typeAndSend("عندي حرارة").value
            rig.clinic.sendChatHandler = { _ in ChatFixture.turn() }
            await rig.chat.retry()
            #expect(rig.clinic.calls == ["sendChat عندي حرارة", "getVisit", "getVisit", "sendChat عندي حرارة"])
        }

        @Test func `a retry whose words landed meanwhile is never sent twice`() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ChatFixture.down }
            rig.clinic.getVisitHandler = { ChatFixture.visit() }
            await rig.typeAndSend("عندي حرارة").value
            rig.clinic.getVisitHandler = {
                ChatFixture.visit(messages: [ChatFixture.opening, ChatFixture.user("عندي حرارة")])
            }
            await rig.chat.retry()
            #expect(rig.clinic.count("sendChat") == 1)
            #expect(rig.chat.failure == nil)
            #expect(rig.refetches == 1)
        }

        @Test func `a known failure offers no Retry, and the patient sends again from the box`() async {
            let rig = ChatRig()
            rig.clinic.sendChatHandler = { _ in throw ClinicError(status: 422, code: "invalid_text", message: "x") }
            await rig.typeAndSend("x").value
            #expect(rig.chat.failure?.retry == false)
            #expect(rig.clinic.count("getVisit") == 0)
        }

        @Test func `the summary needs an intake and an unconfirmed visit`() {
            let noIntake = ChatRig(ChatFixture.visit(messages: [ChatFixture.opening, ChatFixture.summaryMessage]))
            #expect(noIntake.chat.summary == nil)
            let confirmed = ChatRig(ChatFixture.visit(
                messages: [ChatFixture.opening, ChatFixture.summaryMessage], intake: ChatFixture.intake,
                confirmed: true))
            #expect(confirmed.chat.summary == nil)
        }

        @Test func `a draft survives the screen going away and coming back`() {
            let rig = ChatRig()
            rig.chat.setDraft("half a sentence")
            rig.chat.detach()
            rig.attach()
            #expect(rig.chat.draft == "half a sentence")
        }

        @Test func `a confirm that fails after the patient left still lets Yes work on return`() async {
            let rig = ChatRig(ChatFixture.atSummary)
            let answer = Held<ConfirmResponse>()
            rig.clinic.confirmHandler = { try await answer.value() }
            let confirm = Task { await rig.chat.confirm(unsentWords: false) }
            await eventually { rig.clinic.count("confirmIntake") == 1 }
            #expect(rig.chat.confirming)
            rig.chat.detach()
            answer.reject(ChatFixture.down)
            await confirm.value
            #expect(!rig.chat.confirming)
            #expect(rig.chat.confirmError != nil)
        }

        @Test func `a confirm the visit is past refetches through the gate`() async {
            let rig = ChatRig(ChatFixture.atSummary)
            rig.clinic.confirmHandler = {
                throw ClinicError(status: 409, code: "visit_not_in_intake", message: "x")
            }
            await rig.chat.confirm(unsentWords: false)
            #expect(rig.refetches == 1)
            #expect(rig.routed.isEmpty)
        }
    }
}

// MARK: - Screens.test.tsx, S07

@MainActor
@Suite("S07 refill", .timeLimit(.minutes(1)))
struct RefillModelTests {
    private let amlodipine = "amlodipine 5 mg once daily"

    @Test("shows the medicine in Arabic on an Arabic screen")
    func arabicMedicine() {
        #expect(text("refill.title", .ar) == "يمكنك الحصول على دوائك دون زيارة")
        #expect(Strings.bundled.recordTerm(amlodipine, lang: .ar) == "أملوديبين 5 ملغ مرة واحدة يومياً")
    }

    @Test("shows the medicine as stored on an English screen")
    func englishMedicine() {
        #expect(Strings.bundled.recordTerm(amlodipine, lang: .en) == amlodipine)
    }

    @Test("keeps a medicine it has no Arabic for exactly as stored")
    func unknownMedicine() {
        #expect(Strings.bundled.recordTerm("lisinopril 10 mg once daily", lang: .ar) == "lisinopril 10 mg once daily")
    }

    @Test("says the refill line is a demo and invents no number")
    func demoNotice() {
        let clinic = FakeClinic()
        let refill = RefillModel(service: clinic, visitId: ChatFixture.id)
        #expect(!refill.noticed)
        refill.message()
        #expect(refill.noticed)
        #expect(clinic.calls.isEmpty)
        for lang in Lang.allCases {
            #expect(!text("refill.notice", lang).contains { $0.isNumber }, "\(lang)")
        }
        #expect(text("refill.notice", .ar).contains("غير متصل بأي جهة حقيقية"))
    }

    @Test("continues to the centre on request")
    func continues() async {
        let clinic = FakeClinic()
        let refill = RefillModel(service: clinic, visitId: ChatFixture.id)
        var refetches = 0
        var moved = false
        await refill.wantVisit(refetch: { refetches += 1; return nil }, movedOn: { moved = true })
        #expect(clinic.calls == ["continueRefill V1"])
        #expect(refetches == 1)
        #expect(moved)
    }

    @Test("shows a failure in place")
    func failure() async throws {
        let clinic = FakeClinic()
        clinic.continueRefillHandler = { throw ChatFixture.down }
        let refill = RefillModel(service: clinic, visitId: ChatFixture.id)
        var moved = false
        await refill.wantVisit(refetch: { nil }, movedOn: { moved = true })
        let error = try #require(refill.error)
        #expect(errorText(error, strings: .bundled, lang: .ar).contains("تعذر الوصول"))
        #expect(!refill.isBusy)
        #expect(!moved)
    }

    @Test func `a first try that landed refetches so the gate moves on`() async {
        let clinic = FakeClinic()
        clinic.continueRefillHandler = {
            throw ClinicError(status: 409, code: "visit_not_deflected", message: "x")
        }
        let refill = RefillModel(service: clinic, visitId: ChatFixture.id)
        var refetches = 0
        await refill.wantVisit(refetch: { refetches += 1; return nil }, movedOn: {})
        #expect(refetches == 1)
        #expect(refill.error != nil)
    }

    @Test func `the route never names a ticket or a number`() {
        for lang in Lang.allCases {
            for key in ["refill.title", "refill.body", "refill.message", "refill.visit", "refill.usualMedicine"] {
                #expect(!text(key, lang).contains { $0.isNumber }, "\(key) \(lang)")
            }
        }
    }
}

extension ChatResponse {
    fileprivate func withDone() -> ChatResponse {
        var copy = self
        copy.done = true
        return copy
    }
}

// Not ported, because each is about the page and not the chat's logic:
// - "scrolls to the newest message": ChatScreen's `scrollToNewest`, by reading.
// - focus in "focuses the box to change something" and in the voice error cases: ChatScreen,
//   and ChatScreenTests `testChangeFocusesTheField`.
// - `dir="auto"` in "shows role and content only": `Bidi.auto` in ChatBubble.
// - "the scripted note", all three: the app has no real AI mode, so `chat.scripted` is never
//   shown, as "leaves simulated mode to the footer" asks. The footer's AI line is EverywhereTests'.
// - "tells the patient to type after a 502, a 400, a 413": server recognition codes. The app never
//   calls /api/asr, so they cannot happen.
// - Screens.test.tsx S06: EmergencyScreenTests covers each case on the real cover.
