import Foundation
import Synchronization
import Testing
@testable import DawriCore

// MARK: - Fakes

/// One open microphone that the test drives: words as it hears them, then an end.
@MainActor
final class FakeListening: VoiceListening {
    let language: Lang
    let partials: AsyncStream<String>
    private let continuation: AsyncStream<String>.Continuation
    private let heard: String?
    private let failure: VoiceFailure?
    /// Set, Stop waits for the test's answer.
    var held: Held<String>?
    private(set) var cancelled = false
    private(set) var stopped = false

    init(language: Lang, heard: String?, failure: VoiceFailure?) {
        self.language = language
        self.heard = heard
        self.failure = failure
        (partials, continuation) = AsyncStream.makeStream()
    }

    func hear(_ words: String) {
        continuation.yield(words)
    }

    /// The cap, or the system ending it, with nobody tapping Stop.
    func endByItself() {
        continuation.finish()
    }

    func stop() async throws -> String {
        stopped = true
        continuation.finish()
        if let held { return try await held.value() }
        if let failure { throw failure }
        return heard ?? ""
    }

    func cancel() async {
        cancelled = true
        continuation.finish()
    }
}

@MainActor
final class FakeVoiceEngine: VoiceEngine {
    var heard: String?
    var startFailure: VoiceFailure?
    var stopFailure: VoiceFailure?
    var heldStop: Held<String>?
    private(set) var started: [Lang] = []
    private(set) var sessions: [FakeListening] = []

    init(heard: String?, startFailure: VoiceFailure?, stopFailure: VoiceFailure?) {
        self.heard = heard
        self.startFailure = startFailure
        self.stopFailure = stopFailure
    }

    func start(language: Lang) async throws -> any VoiceListening {
        started.append(language)
        if let startFailure { throw startFailure }
        let session = FakeListening(language: language, heard: heard, failure: stopFailure)
        session.held = heldStop
        sessions.append(session)
        return session
    }
}

/// A clock the test moves by hand, for the listening timer.
final class HandClock: Sendable {
    private let now = Mutex(Date(timeIntervalSince1970: 1_800_000_000))

    func read() -> Date { now.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { now.withLock { $0 += seconds } }
}

@MainActor
struct VoiceRig {
    let engine: FakeVoiceEngine
    let clock = HandClock()
    let model: VoiceModel

    init(
        heard: String? = "عندي حرارة", startFailure: VoiceFailure? = nil,
        stopFailure: VoiceFailure? = nil, language: Lang = .ar
    ) {
        engine = FakeVoiceEngine(heard: heard, startFailure: startFailure, stopFailure: stopFailure)
        let clock = self.clock
        model = VoiceModel(engine: engine, language: language, now: { clock.read() })
    }

    /// The mic, then Stop.
    func record() async {
        await model.start()
        await model.stop()
    }
}

// MARK: - The port of useVoice.ts

@MainActor
@Suite("Patient: voice", .timeLimit(.minutes(1)))
struct VoiceModelTests {
    @Test func `it walks idle, starting, listening, transcribing, confirm`() async {
        let rig = VoiceRig()
        #expect(rig.model.step == .idle)
        let answer = Held<String>()
        let slow = SlowEngine(answer: answer)
        let model = VoiceModel(engine: slow, language: .ar)
        let start = Task { await model.start() }
        await eventually { model.step == .starting }
        answer.resolve("x")
        await start.value
        #expect(model.step == .listening)

        let words = Held<String>()
        rig.engine.heldStop = words
        await rig.model.start()
        #expect(rig.model.step == .listening)
        let stop = Task { await rig.model.stop() }
        await eventually { rig.model.step == .transcribing }
        words.resolve("عندي حرارة")
        await stop.value
        #expect(rig.model.step == .confirm)
        #expect(rig.model.transcript == "عندي حرارة")
    }

    @Test func `the engine starts in the screen's language`() async {
        let rig = VoiceRig(language: .en)
        await rig.model.start()
        #expect(rig.engine.started == [.en])
    }

    @Test func `the live words show while listening and go when it ends`() async {
        let rig = VoiceRig()
        await rig.model.start()
        rig.engine.sessions[0].hear("عندي")
        await eventually { rig.model.partial == "عندي" }
        await rig.model.stop()
        #expect(rig.model.partial.isEmpty)
    }

    @Test func `the timer counts whole seconds from the start`() async {
        let rig = VoiceRig()
        await rig.model.start()
        #expect(rig.model.seconds == 0)
        rig.clock.advance(12.6)
        await eventually { rig.model.seconds == 12 }
        #expect(ChatRules.clock(rig.model.seconds) == "0:12")
        await rig.model.stop()
        rig.clock.advance(30)
        try? await Task.sleep(for: .milliseconds(400))
        #expect(rig.model.seconds == 12, "The timer stops with the microphone")
    }

    @Test func `a language switch while listening restarts in the new language`() async {
        let rig = VoiceRig()
        await rig.model.start()
        await rig.model.languageChanged(to: .en)
        #expect(rig.engine.started == [.ar, .en])
        #expect(rig.engine.sessions[0].cancelled)
        #expect(rig.model.step == .listening)
        // The words from the first session no longer land.
        rig.engine.sessions[0].hear("old")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(rig.model.partial.isEmpty)
    }

    @Test func `a language switch at any other step keeps what it has`() async {
        let rig = VoiceRig()
        await rig.model.languageChanged(to: .en)
        #expect(rig.engine.started.isEmpty)
        await rig.model.start()
        await rig.model.stop()
        await rig.model.languageChanged(to: .ar)
        #expect(rig.model.step == .confirm)
        #expect(rig.model.transcript == "عندي حرارة")
        #expect(rig.engine.started == [.en])
    }

    @Test func `leaving closes the microphone and keeps nothing heard`() async {
        let rig = VoiceRig()
        await rig.model.start()
        rig.engine.sessions[0].hear("half")
        await rig.model.leave()
        #expect(rig.engine.sessions[0].cancelled)
        #expect(rig.model.step == .idle)
        #expect(rig.model.partial.isEmpty)
        #expect(rig.model.transcript.isEmpty)
    }

    @Test func `leaving keeps a transcript waiting on the confirm step, as a draft`() async {
        let rig = VoiceRig()
        await rig.model.start()
        await rig.model.stop()
        await rig.model.leave()
        #expect(rig.model.step == .confirm)
        #expect(rig.model.transcript == "عندي حرارة")
    }

    @Test func `an answer for a microphone the patient left changes nothing`() async {
        let answer = Held<String>()
        let model = VoiceModel(engine: SlowEngine(answer: answer), language: .ar)
        let start = Task { await model.start() }
        await eventually { model.step == .starting }
        await model.leave()
        answer.resolve("x")
        await start.value
        #expect(model.step == .idle)
    }

    @Test func `Clear and a send both close the confirm step`() async {
        let rig = VoiceRig()
        await rig.record()
        rig.model.reset()
        #expect(rig.model.step == .idle)
        #expect(rig.model.transcript.isEmpty)
    }

    @Test func `the transcript is held to the box's limit`() async {
        let rig = VoiceRig(heard: String(repeating: "ا", count: 2100))
        await rig.record()
        #expect(rig.model.transcript.utf16.count == ChatRules.maxText)
        rig.model.setTranscript(String(repeating: "b", count: 3000))
        #expect(rig.model.transcript.utf16.count == ChatRules.maxText)
    }

    @Test func `a new start clears the last error and transcript`() async {
        let rig = VoiceRig(stopFailure: .failed)
        await rig.record()
        #expect(rig.model.error == .failed)
        rig.engine.stopFailure = nil
        await rig.model.start()
        #expect(rig.model.error == nil)
        #expect(rig.model.transcript.isEmpty)
    }

    @Test func `typing clears a voice error`() async {
        let rig = VoiceRig(startFailure: .denied)
        await rig.model.start()
        #expect(rig.model.error == .denied)
        rig.model.clearError()
        #expect(rig.model.error == nil)
    }

    @Test(arguments: [
        (VoiceFailure.denied, "voice.error.denied"), (.unsupported, "voice.error.unsupported"),
        (.unavailable, "voice.unavailableOnDevice"), (.decode, "voice.error.decode"),
        (.blank, "voice.error.failed"), (.failed, "voice.error.failed"),
    ])
    func `each failure has its line, and every line says to type`(_ failure: VoiceFailure, _ key: String) {
        #expect(failure.textKey == key)
        for lang in Lang.allCases {
            let line = Strings.bundled.translate(lang, key)
            #expect(line != key)
        }
        #expect(Strings.bundled.translate(.en, key).contains("type your message"))
    }

    @Test func `an error the engine did not name is a plain failure`() async {
        struct Odd: Error {}
        #expect(VoiceFailure(Odd()) == .failed)
        #expect(VoiceFailure(VoiceFailure.denied) == .denied)
    }

    @Test func `the build with no recogniser says so and never falls back`() async {
        let model = VoiceModel(engine: UnavailableVoiceEngine(), language: .ar)
        await model.start()
        #expect(model.error == .unavailable)
        #expect(model.step == .idle)
        #expect(Strings.bundled.translate(.en, model.error!.textKey)
            == "Voice is not available on this phone. Please type your message.")
    }

    @Test func `Stop does nothing unless the microphone is open`() async {
        let rig = VoiceRig()
        await rig.model.stop()
        #expect(rig.model.step == .idle)
        #expect(rig.engine.sessions.isEmpty)
    }
}

/// An engine whose microphone opens when the test says.
@MainActor
private final class SlowEngine: VoiceEngine {
    let answer: Held<String>

    init(answer: Held<String>) {
        self.answer = answer
    }

    func start(language: Lang) async throws -> any VoiceListening {
        let heard = try await answer.value()
        return FakeListening(language: language, heard: heard, failure: nil)
    }
}
