import Foundation
import Observation

/// `VoiceStep` in frontend/src/features/chat/useVoice.ts.
public enum VoiceStep: String, Sendable, Equatable, CaseIterable {
    case idle, starting, listening, transcribing, confirm
}

/// Why voice did not give a transcript. Each one ends by telling the patient to type.
public enum VoiceFailure: Error, Sendable, Equatable {
    /// The microphone or speech recognition permission is refused. The web's `denied`.
    case denied
    /// This device has no microphone or recogniser at all. The web's `unsupported`.
    case unsupported
    /// Recognition on this phone is not available, and nothing falls back to a server.
    case unavailable
    /// What was heard could not be read. The web's `decode`.
    case decode
    /// Nothing was heard. The web's `blank`.
    case blank
    /// Anything else.
    case failed

    init(_ error: any Error) {
        self = (error as? VoiceFailure) ?? .failed
    }

    /// `voiceErrorText` in voiceText.ts, without the server codes, because the app never sends
    /// audio anywhere. `unavailable` is the phone's own line.
    public var textKey: String {
        switch self {
        case .denied: "voice.error.denied"
        case .unsupported: "voice.error.unsupported"
        case .unavailable: "voice.unavailableOnDevice"
        case .decode: "voice.error.decode"
        case .blank, .failed: "voice.error.failed"
        }
    }
}

/// Recognition on the phone. The real one, on `Speech` with on-device recognition only, is a
/// later phase. An engine never stores or sends audio: the only thing that leaves it is text.
public protocol VoiceEngine: Sendable {
    /// Opens the microphone and starts recognising in this language. Throws a `VoiceFailure`
    /// when it cannot.
    func start(language: Lang) async throws -> any VoiceListening
}

/// One open microphone.
public protocol VoiceListening: Sendable {
    /// The words heard so far, live. It finishes when listening ends by itself, at a time cap or
    /// when the system ends it, and the model then stops as if the patient had tapped Stop.
    var partials: AsyncStream<String> { get }
    /// Closes the microphone and gives the final words.
    func stop() async throws -> String
    /// Closes the microphone and keeps nothing.
    func cancel() async
}

/// What a build with no recogniser has. It says so, and the patient types.
public struct UnavailableVoiceEngine: VoiceEngine {
    public init() {}

    public func start(language: Lang) async throws -> any VoiceListening {
        throw VoiceFailure.unavailable
    }
}

/// The port of useVoice.ts over a `VoiceEngine`: idle, starting, listening, transcribing,
/// confirm. The transcript is only what the engine heard, and nothing is sent from here: the
/// patient sends it from the confirm step.
@MainActor
@Observable
public final class VoiceModel {
    public private(set) var step = VoiceStep.idle
    public private(set) var seconds = 0
    /// The words so far while listening.
    public private(set) var partial = ""
    /// Only what the engine heard, then whatever the patient edits it to.
    public private(set) var transcript = ""
    public private(set) var error: VoiceFailure?

    @ObservationIgnored private let engine: any VoiceEngine
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored public private(set) var language: Lang
    @ObservationIgnored private var session: (any VoiceListening)?
    /// Bumped by every start and every end, so an answer for an old attempt changes nothing.
    @ObservationIgnored private var attempt = 0
    @ObservationIgnored private var ticking: Task<Void, Never>?
    @ObservationIgnored private var following: Task<Void, Never>?

    public init(engine: any VoiceEngine, language: Lang, now: @escaping @Sendable () -> Date = { Date() }) {
        self.engine = engine
        self.language = language
        self.now = now
    }

    /// The mic button, and Try again on the confirm step.
    public func start() async {
        attempt += 1
        let mine = attempt
        await closeSession()
        error = nil
        transcript = ""
        partial = ""
        step = .starting
        do {
            let opened = try await engine.start(language: language)
            guard mine == attempt else {
                // The patient left, or switched language, while the microphone opened.
                await opened.cancel()
                return
            }
            session = opened
            seconds = 0
            startTicking()
            step = .listening
            following = Task { [weak self] in
                for await words in opened.partials {
                    guard let self, mine == self.attempt else { return }
                    self.partial = words
                }
                // The cap, or the system ending it, gets here with nobody tapping Stop.
                guard let self, mine == self.attempt, self.step == .listening else { return }
                await self.stop()
            }
        } catch {
            fail(error, attempt: mine)
        }
    }

    /// Stop: the words go to the confirm step, or the patient is told to type.
    public func stop() async {
        guard step == .listening, let current = session else { return }
        let mine = attempt
        session = nil
        stopTicking()
        step = .transcribing
        do {
            let heard = try await current.stop().trimmingCharacters(in: .whitespacesAndNewlines)
            guard mine == attempt else { return }
            if heard.isEmpty { throw VoiceFailure.blank }
            transcript = ChatRules.limited(heard)
            partial = ""
            step = .confirm
        } catch {
            fail(error, attempt: mine)
        }
    }

    /// The confirm field.
    public func setTranscript(_ text: String) {
        transcript = ChatRules.limited(text)
    }

    /// Closes the confirm step: Clear, and after a send.
    public func reset() {
        transcript = ""
        step = .idle
    }

    public func clearError() {
        error = nil
    }

    /// A language switch while listening restarts in the new language. Any other step keeps
    /// what it has.
    public func languageChanged(to next: Lang) async {
        guard next != language else { return }
        language = next
        if step == .starting || step == .listening {
            await start()
        }
    }

    /// The patient left the chat. The microphone closes and nothing heard is kept, but a
    /// transcript waiting on the confirm step stays, as a draft does.
    public func leave() async {
        guard step == .starting || step == .listening || step == .transcribing else { return }
        attempt += 1
        stopTicking()
        partial = ""
        step = .idle
        await closeSession()
    }

    private func closeSession() async {
        following?.cancel()
        following = nil
        let open = session
        session = nil
        await open?.cancel()
    }

    private func fail(_ cause: any Error, attempt mine: Int) {
        stopTicking()
        guard mine == attempt else { return }
        session = nil
        partial = ""
        error = VoiceFailure(cause)
        step = .idle
    }

    private func startTicking() {
        stopTicking()
        let startedAt = now()
        let clock = now
        ticking = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, let self else { return }
                self.seconds = max(0, Int(clock().timeIntervalSince(startedAt)))
            }
        }
    }

    private func stopTicking() {
        ticking?.cancel()
        ticking = nil
    }
}
