@preconcurrency import AVFAudio
import DawriCore
import Foundation
@preconcurrency import Speech
import Synchronization

/// Recognition with Apple's `Speech`, on this phone only. Every request sets
/// `requiresOnDeviceRecognition`, and `VoiceAvailability.open` makes none unless the recogniser
/// runs on this phone. The microphone feeds the request through an `AVAudioEngine` tap and
/// nothing else: no file, no recorder, and no buffer kept. When on-device recognition is not
/// available in the patient's language it says so, and the patient types. There is never a
/// server fallback.
///
/// Permission prompts come only from `start`, which only the mic tap calls.
struct SpeechVoiceEngine: VoiceEngine {
    init() {}

    func start(language: Lang) async throws -> any VoiceListening {
        try await VoiceAvailability.open(language, on: SystemSpeechPlatform()) { locale in
            try await SpeechListening.open(locale: locale)
        }
    }
}

/// `Speech` and `AVFAudio` as the voice gate sees them.
private struct SystemSpeechPlatform: SpeechPlatform {
    func supportedLocales() async -> Set<String> {
        Set(SFSpeechRecognizer.supportedLocales().map(\.identifier))
    }

    func conditions(locale: String) async -> VoiceConditions {
        let recogniser = SFSpeechRecognizer(locale: Locale(identifier: locale))
        return VoiceConditions(
            speech: Self.speech(SFSpeechRecognizer.authorizationStatus()),
            mic: Self.mic(AVAudioApplication.shared.recordPermission),
            hasRecogniser: recogniser != nil,
            supportsOnDevice: recogniser?.supportsOnDeviceRecognition ?? false,
            isAvailable: recogniser?.isAvailable ?? false)
    }

    func requestMicrophone() async {
        _ = await AVAudioApplication.requestRecordPermission()
    }

    func requestSpeech() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            SFSpeechRecognizer.requestAuthorization { _ in done.resume() }
        }
    }

    private static func speech(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechPermission {
        switch status {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    private static func mic(_ permission: AVAudioApplication.recordPermission) -> MicPermission {
        switch permission {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .undetermined
        @unknown default: .denied
        }
    }
}

/// One open microphone on the phone's recogniser.
///
/// `@unchecked Sendable`: the audio engine, the request and the task are set once in `open` and
/// then touched only by `close`, which the `Mutex` lets run once. The tap only appends to the
/// request, which `Speech` allows from the audio thread.
private final class SpeechListening: VoiceListening, @unchecked Sendable {
    /// useVoice.ts `MAX_SECONDS`: listening ends by itself after a minute.
    static let cap: Duration = .seconds(60)
    /// How long Stop waits for the recogniser's last words before taking the latest ones.
    static let finalWait: Duration = .seconds(2)
    /// A short wait before the audio session starts, so the micStart haptic, fired as the step
    /// turns to starting, plays before iOS mutes haptics for recording.
    static let hapticLead: Duration = .milliseconds(150)

    let partials: AsyncStream<String>

    private struct State {
        var latest = ""
        var heardFinal = false
        var closed = false
        var waiter: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    private let feed: AsyncStream<String>.Continuation
    private let audio = AVAudioEngine()
    private let request = SFSpeechAudioBufferRecognitionRequest()
    private let recogniser: SFSpeechRecognizer
    private var task: SFSpeechRecognitionTask?
    private var cap: Task<Void, Never>?

    private init(recogniser: SFSpeechRecognizer) {
        self.recogniser = recogniser
        (partials, feed) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
    }

    static func open(locale: String) async throws -> SpeechListening {
        guard let recogniser = SFSpeechRecognizer(locale: Locale(identifier: locale)),
              recogniser.supportsOnDeviceRecognition
        else { throw VoiceFailure.unavailable }
        try await Task.sleep(for: hapticLead)
        let listening = SpeechListening(recogniser: recogniser)
        do {
            try listening.begin()
        } catch {
            listening.close(keepWords: false)
            throw (error as? VoiceFailure) ?? VoiceFailure.failed
        }
        return listening
    }

    private func begin() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.taskHint = .dictation

        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw VoiceFailure.unsupported }
        let request = request
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            // Straight into the recogniser. The buffer is not kept.
            request.append(buffer)
        }
        audio.prepare()
        try audio.start()

        task = recogniser.recognitionTask(with: request) { [weak self] result, error in
            self?.heard(result: result, error: error)
        }
        cap = Task { [weak self] in
            try? await Task.sleep(for: Self.cap)
            guard !Task.isCancelled else { return }
            // The model sees the words end and stops as if the patient had tapped Stop.
            self?.feed.finish()
        }
    }

    private func heard(result: SFSpeechRecognitionResult?, error: (any Error)?) {
        let words = result?.bestTranscription.formattedString
        let ended = result?.isFinal == true || error != nil
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            if let words, !words.isEmpty { state.latest = words }
            guard ended else { return nil }
            state.heardFinal = true
            defer { state.waiter = nil }
            return state.waiter
        }
        if let words, !words.isEmpty { feed.yield(words) }
        if ended {
            // The recogniser ended by itself: the model stops and asks for the words.
            feed.finish()
            waiter?.resume()
        }
    }

    func stop() async throws -> String {
        stopAudio()
        request.endAudio()
        await waitForFinal()
        let words = state.withLock { $0.latest }
        close(keepWords: true)
        return words
    }

    func cancel() async {
        close(keepWords: false)
    }

    /// Waits for the recogniser's final result, or `finalWait`, whichever is first.
    private func waitForFinal() async {
        let timer = Task { [weak self] in
            try? await Task.sleep(for: Self.finalWait)
            self?.releaseWaiter()
        }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let ready = state.withLock { state -> Bool in
                if state.heardFinal || state.closed { return true }
                state.waiter = done
                return false
            }
            if ready { done.resume() }
        }
        timer.cancel()
    }

    private func releaseWaiter() {
        let waiter = state.withLock { state -> CheckedContinuation<Void, Never>? in
            defer { state.waiter = nil }
            return state.waiter
        }
        waiter?.resume()
    }

    private func stopAudio() {
        if audio.isRunning { audio.stop() }
        audio.inputNode.removeTap(onBus: 0)
    }

    /// Closes everything once: the microphone, the recognition, the cap and the audio session,
    /// which lets other audio resume. `keepWords` false drops what was heard.
    private func close(keepWords: Bool) {
        let first = state.withLock { state -> Bool in
            guard !state.closed else { return false }
            state.closed = true
            if !keepWords { state.latest = "" }
            return true
        }
        guard first else { return }
        cap?.cancel()
        stopAudio()
        request.endAudio()
        if keepWords { task?.finish() } else { task?.cancel() }
        task = nil
        feed.finish()
        releaseWaiter()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
