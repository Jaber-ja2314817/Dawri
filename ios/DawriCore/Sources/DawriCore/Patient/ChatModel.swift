import Foundation
import Observation

/// The closing read-back, which the summary card shows in place of its bubble.
public struct ChatSummary: Sendable, Equatable {
    public let text: String
    public let service: Service
    /// Where the message sits in the conversation.
    public let index: Int
}

/// A failed send, as the screen shows it.
public struct ChatFailure: Sendable {
    public let error: any Error
    /// The 45 s limit ended it: `chat.timeout`, and the words stay in the box.
    public let timedOut: Bool
    /// The turn may have landed, so Retry looks before it sends. Only then is Retry offered.
    public let retry: Bool
}

/// The port of frontend/src/features/chat/useChat.ts over `ClinicService`.
///
/// One lives for each visit, above the screen, so leaving S05 ends nothing: a turn in flight may
/// be a red flag, and its answer has to be heard. The draft lives here too, so it survives a
/// language switch, a trip to Home and back, and anything else short of signing out.
///
/// The screen attaches while it shows, which is the web's `live`. Only a red flag may move a
/// patient who has left, and only the session that sent the turn.
@MainActor
@Observable
public final class ChatModel {
    /// What the app does when a turn or a confirm moves the visit on.
    public struct Routes {
        /// S06, at once. Called before anything else, with no second request.
        public var emergency: @MainActor () -> Void
        /// S07, in place of the chat.
        public var refill: @MainActor () -> Void
        /// S08, after Yes on the summary.
        public var movedOn: @MainActor () -> Void
        /// Every failure the patient is shown, so a 401 can end the session as it does anywhere.
        public var failed: @MainActor (any Error) -> Void

        public init(
            emergency: @escaping @MainActor () -> Void, refill: @escaping @MainActor () -> Void,
            movedOn: @escaping @MainActor () -> Void,
            failed: @escaping @MainActor (any Error) -> Void = { _ in }
        ) {
            self.emergency = emergency
            self.refill = refill
            self.movedOn = movedOn
            self.failed = failed
        }
    }

    /// The screen's refetch: reads the visit again through its gate, so a visit that moved on
    /// takes the patient with it, and gives back what it read.
    public typealias Refetch = @MainActor () async -> Visit?

    /// A turn the visit has not caught up with yet. It stops showing as soon as the visit has it.
    private struct LocalTurn {
        var baseline: Int
        var user: String
        var reply: String?
        var done = false
        var intake: Intake?
    }

    private struct Failure {
        var text: String
        var baseline: Int
        var error: any Error
        /// Set when the turn may have landed, so a retry has to look before it sends.
        var retry: Bool
        var fromBox: Bool
    }

    public let visitId: String
    /// The box. `setDraft` keeps it within `MAX_TEXT`.
    public private(set) var draft = ""
    public private(set) var thinking = false
    public private(set) var confirming = false
    public private(set) var confirmError: (any Error)?
    /// The last visit the screen or a refetch gave.
    public private(set) var visit: Visit
    /// Counts sends that went out, for the `.sent` haptic.
    public private(set) var sentCount = 0
    private var local: LocalTurn?
    private var failed: Failure?

    @ObservationIgnored private let service: any ClinicService
    @ObservationIgnored private let routes: Routes
    @ObservationIgnored private let session: @MainActor () -> String?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var unresolved: Failure?
    @ObservationIgnored private var refetchHook: Refetch?
    @ObservationIgnored private var attachment = 0

    /// - Parameters:
    ///   - session: who is signed in now, compared with who sent a turn.
    ///   - sleep: the clock of the 45 s limit. Tests hold it.
    public init(
        service: any ClinicService, visit: Visit, routes: Routes,
        session: @escaping @MainActor () -> String?,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.service = service
        self.visitId = visit.visitId
        self.visit = visit
        self.routes = routes
        self.session = session
        self.sleep = sleep
    }

    // The screen

    /// The web's `live`: true while S05 shows this chat.
    public var isLive: Bool { refetchHook != nil }

    /// S05 appeared. Its refetch reads through the gate. Returns the token `detach` takes, so a
    /// screen that goes away after a new one appeared cannot detach the new one.
    @discardableResult
    public func attach(refetch: @escaping Refetch) -> Int {
        attachment += 1
        refetchHook = refetch
        return attachment
    }

    /// S05 went away. Nothing in flight stops.
    public func detach(_ token: Int? = nil) {
        guard token == nil || token == attachment else { return }
        refetchHook = nil
    }

    /// The visit as the gate has it now.
    public func sync(_ next: Visit) {
        guard next.visitId == visitId, next != visit else { return }
        visit = next
    }

    public func setDraft(_ text: String) {
        draft = ChatRules.limited(text)
    }

    public var failure: ChatFailure? {
        failed.map {
            ChatFailure(error: $0.error, timedOut: ChatRules.isAbort($0.error), retry: $0.retry)
        }
    }

    /// The conversation, with a turn the visit has not caught up with on the end.
    public var messages: [ChatMessage] { messages(in: visit) }

    /// The same, over the visit the screen holds, which may be newer than the last sync.
    public func messages(in visit: Visit) -> [ChatMessage] {
        let kept = visit.chat.messages
        guard let local, kept.count <= local.baseline else { return kept }
        var extra = [ChatMessage(role: .user, content: local.user, slot: nil)]
        if let reply = local.reply {
            extra.append(ChatMessage(
                role: .assistant, content: reply, slot: local.done ? ChatRules.summarySlot : nil))
        }
        return kept + extra
    }

    public var summary: ChatSummary? { summary(in: visit) }

    /// Only while the last message is the read-back. A correction can bring a question instead,
    /// and the old intake stays until it is answered.
    public func summary(in visit: Visit) -> ChatSummary? {
        let all = messages(in: visit)
        guard let intake = local?.intake ?? visit.intake, !visit.confirmedByPatient,
              let last = all.last, last.role == .assistant, last.slot == ChatRules.summarySlot
        else { return nil }
        return ChatSummary(text: last.content, service: intake.service, index: all.count - 1)
    }

    // Sending

    /// Sends the box.
    public func submit() async {
        await send(draft, fromBox: true)
    }

    /// Sends a confirmed transcript. The box keeps whatever is typed in it.
    public func sendText(_ text: String) async {
        await send(text, fromBox: false)
    }

    public func retry() async {
        guard let failed else { return }
        // The patient may have fixed the words in the box before tapping Retry.
        let edited = failed.fromBox && !ChatRules.isBlank(draft)
        await send(edited ? draft : failed.text, fromBox: failed.fromBox)
    }

    private func send(_ raw: String, fromBox: Bool) async {
        let text = ChatRules.outgoing(raw)
        guard !text.isEmpty, !inFlight else { return }
        inFlight = true
        let sentBy = session()

        let earlier = unresolved?.text == text ? unresolved : nil
        let baseline = earlier?.baseline ?? visit.chat.messages.count
        unresolved = nil
        failed = nil
        thinking = true
        local = LocalTurn(baseline: baseline, user: text)
        if fromBox { draft = "" }
        sentCount += 1

        defer {
            inFlight = false
            // The web leaves this to the unmount. Here the model outlives the screen, so it has
            // to end, or the patient would come back to a chat that thinks for ever.
            thinking = false
        }

        do {
            if earlier != nil, try await landed(baseline: baseline, text: text) {
                if isLive { await refetch() } else { await lookAfterLeaving(sentBy) }
                return
            }
            let response = try await timed { [service, visitId] in
                try await service.sendChat(visitId: visitId, text: text)
            }
            await applyTurn(response, baseline: baseline, text: text, sentBy: sentBy)
        } catch {
            if !isLive {
                let fresh = await lookAfterLeaving(sentBy)
                keepForReturn(
                    Failure(
                        text: text, baseline: baseline, error: error,
                        retry: ChatRules.isUnknownOutcome(error), fromBox: fromBox),
                    fresh: fresh)
                return
            }
            if (error as? ClinicError)?.code == "visit_not_in_intake" {
                // The visit moved on. The gate takes the patient to where it is now.
                await refetch()
                fail(Failure(text: text, baseline: baseline, error: error, retry: false, fromBox: fromBox))
                return
            }
            if !ChatRules.isUnknownOutcome(error) {
                fail(Failure(text: text, baseline: baseline, error: error, retry: false, fromBox: fromBox))
                return
            }
            var arrived = false
            do {
                arrived = try await landed(baseline: baseline, text: text)
            } catch {
                // Still no answer. The retry looks again before it sends anything.
            }
            if !isLive {
                let fresh = await lookAfterLeaving(sentBy)
                if !arrived {
                    keepForReturn(
                        Failure(text: text, baseline: baseline, error: error, retry: true, fromBox: fromBox),
                        fresh: fresh)
                }
                return
            }
            if arrived {
                await refetch()
            } else {
                fail(Failure(text: text, baseline: baseline, error: error, retry: true, fromBox: fromBox))
            }
        }
    }

    /// The order matters: a red flag beats everything, and nothing may follow it.
    private func applyTurn(_ response: ChatResponse, baseline: Int, text: String, sentBy: String?) async {
        if response.emergency {
            // Before anything else, and with no second request: this answer alone is enough.
            toEmergency(sentBy)
            return
        }
        guard isLive else { return }  // Only a red flag may still move a patient who has left.
        if response.refill != nil {
            routes.refill()
            return
        }
        local = LocalTurn(
            baseline: baseline, user: text, reply: response.reply, done: response.done,
            intake: response.intake)
        await refetch()
    }

    /// From any patient screen, for the patient who sent the turn. A new sign-in is someone else.
    private func toEmergency(_ sentBy: String?) {
        guard session() == sentBy else { return }
        routes.emergency()
    }

    /// The box gets the words back: it was cleared on send, or holds something typed before a
    /// transcript went.
    private func fail(_ next: Failure) {
        unresolved = next.retry ? next : nil
        failed = next
        local = nil
        if next.fromBox || draft.isEmpty { draft = next.text }
        routes.failed(next.error)
    }

    /// The web forgets a failure that lands after the screen unmounted. This model outlives the
    /// screen, so the words wait in the box for the patient's return, unless the visit shows they
    /// landed or that the chat is over.
    private func keepForReturn(_ next: Failure, fresh: Visit?) {
        if let fresh, fresh.stage != .intake
            || ChatRules.isStored(fresh.chat.messages, baseline: next.baseline, text: next.text) {
            local = nil
            return
        }
        fail(next)
    }

    /// The turn failed after the patient left: only the visit can say if it was a red flag.
    @discardableResult
    private func lookAfterLeaving(_ sentBy: String?) async -> Visit? {
        do {
            let fresh = try await timed { [service, visitId] in try await service.getVisit(visitId: visitId) }
            sync(fresh)
            if fresh.stage == .emergency { toEmergency(sentBy) }
            return fresh
        } catch {
            // Nothing more to go on. Home still leads to S06 once the list shows the visit.
            return nil
        }
    }

    /// True when the visit shows the message landed, or that the chat is over anyway.
    private func landed(baseline: Int, text: String) async throws -> Bool {
        let fresh = try await timed { [service, visitId] in try await service.getVisit(visitId: visitId) }
        return fresh.stage != .intake || ChatRules.isStored(fresh.chat.messages, baseline: baseline, text: text)
    }

    private func refetch() async {
        guard let refetchHook, let fresh = await refetchHook() else { return }
        sync(fresh)
    }

    // Confirming

    /// Yes on the summary. Rules read only what is sent, so words in the box or on their way
    /// from the microphone hold it back, as the disabled button does on the web.
    public func confirm(unsentWords: Bool) async {
        guard !confirming, !unsentWords else { return }
        confirming = true
        confirmError = nil
        do {
            _ = try await service.confirmIntake(visitId: visitId, service: nil)
            routes.movedOn()
        } catch {
            if (error as? ClinicError)?.code == "visit_not_in_intake" { await refetch() }
            // The web sets these only while mounted. This model outlives the screen, so it always
            // does, or Yes would stay spinning for a patient who comes back.
            confirmError = error
            confirming = false
            routes.failed(error)
        }
    }

    // The 45 s limit

    /// Runs one request under the limit. The limit wins the race even when the request ignores
    /// cancellation, so a request that never answers still ends in a failure the patient sees.
    private func timed<T: Sendable>(
        _ request: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let race = Race<T>()
        let sleep = self.sleep
        return try await withCheckedThrowingContinuation { continuation in
            race.continuation = continuation
            let work = Task { @MainActor in
                do {
                    race.finish(.success(try await request()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            race.timer = Task { @MainActor in
                do {
                    try await sleep(ChatRules.turnTimeout)
                } catch {
                    return  // Cancelled: the request answered first.
                }
                race.finish(.failure(CancellationError()))
                work.cancel()
            }
        }
    }
}

/// One answer to whichever finishes first: the request or the limit.
@MainActor
private final class Race<T: Sendable> {
    var continuation: CheckedContinuation<T, any Error>?
    var timer: Task<Void, Never>?

    func finish(_ result: Result<T, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        continuation.resume(with: result)
    }
}

/// S07's one request: "I still want a visit". The port of `wantVisit` in
/// frontend/src/pages/patient/Refill.tsx. It lives beside the chat because the chat is what sent
/// the patient there.
@MainActor
@Observable
public final class RefillModel {
    public private(set) var isBusy = false
    public private(set) var error: (any Error)?
    /// `refill.message` was tapped. Nothing is sent anywhere: the notice says this is a demo.
    public private(set) var noticed = false

    @ObservationIgnored private let service: any ClinicService
    @ObservationIgnored public let visitId: String

    public init(service: any ClinicService, visitId: String) {
        self.service = service
        self.visitId = visitId
    }

    public func message() {
        noticed = true
    }

    /// Continues to the centre as a GP visit. A first try that landed comes back as
    /// `visit_not_deflected`, and the refetch lets the gate move on.
    public func wantVisit(refetch: ChatModel.Refetch, movedOn: @MainActor () -> Void) async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        do {
            _ = try await service.continueRefill(visitId: visitId)
            _ = await refetch()
            movedOn()
        } catch {
            if (error as? ClinicError)?.code == "visit_not_deflected" { _ = await refetch() }
            self.error = error
            isBusy = false
        }
    }
}
