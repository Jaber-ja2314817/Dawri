#if DEBUG
import DawriCore
import Foundation
import Synchronization
import SwiftUI

/// S05's DEBUG hooks, read from the launch arguments. All of it compiles out of Release.
///
///     -demoVoice listening|transcribing|confirm|denied|failed|unavailable
///         a scripted recogniser in place of the phone's, and the mic tapped on arrival
///     -demoDraft <text>|@answer  the box starts with these words, or the demo's first answer
///     -demoChatAction send|confirm
///         on arrival, sends the box, or taps Yes on the summary
///
/// The scripted recogniser hears one of the demo's own sentences. Nothing here decides an
/// outcome: a sent line still goes through the real clinic.
enum DemoChat {
    enum VoiceMode: String, Sendable {
        case listening, transcribing, confirm, denied, failed, unavailable
    }

    static let voiceMode = DemoLaunch.current?.argument("demoVoice").flatMap(VoiceMode.init(rawValue:))
    private static let rawDraft = DemoLaunch.current?.argument("demoDraft")
    static let action = DemoLaunch.current?.argument("demoChatAction")

    /// `-demoDraft`, where `@answer` is the demo's first answer in the screen's language.
    static func draft(lang: Lang) -> String? {
        rawDraft == "@answer" ? heard(lang) : rawDraft
    }

    /// The recogniser for `-demoVoice`, or nil to use the phone's own.
    static var engine: (any VoiceEngine)? {
        voiceMode.map(ScriptedVoiceEngine.init(mode:))
    }

    /// The listening clock for a screenshot: the first read is the start, every later one is
    /// 12 seconds on, so the timer reads `0:12` however long the shot takes to settle.
    static let now: @Sendable () -> Date = {
        let reads = Mutex(0)
        let start = Date()
        return {
            let count = reads.withLock { value -> Int in
                value += 1
                return value
            }
            return count == 1 ? start : start.addingTimeInterval(12)
        }
    }()

    /// One run per launch, so coming back to S05 does not repeat it.
    private static let done = Mutex(false)

    /// What the launch asked S05 to do on arrival. It waits until the screen has stayed: a stack
    /// that starts with a path can show its first screen, take it away and show it again, and
    /// that first copy's task is cancelled with it.
    @MainActor
    static func act(chat: ChatModel, voice: VoiceModel) async {
        guard action != nil || voiceMode != nil else { return }
        try? await Task.sleep(for: .milliseconds(600))
        guard !Task.isCancelled else { return }
        let first = done.withLock { done -> Bool in
            defer { done = true }
            return !done
        }
        guard first else { return }
        switch action {
        case "send": await chat.submit()
        case "confirm": await chat.confirm(unsentWords: false)
        default: break
        }
        guard let voiceMode else { return }
        await voice.start()
        switch voiceMode {
        case .transcribing, .confirm, .failed:
            await voice.stop()
        case .listening, .denied, .unavailable:
            break
        }
    }

    fileprivate static func heard(_ lang: Lang) -> String {
        lang == .ar ? "عندي حرارة وكحة من ثلاث أيام" : "I have a fever and cough for three days"
    }
}

/// A recogniser that behaves as `-demoVoice` says, and hears nothing real.
private struct ScriptedVoiceEngine: VoiceEngine {
    let mode: DemoChat.VoiceMode

    func start(language: Lang) async throws -> any VoiceListening {
        switch mode {
        case .denied: throw VoiceFailure.denied
        case .unavailable: throw VoiceFailure.unavailable
        default: return ScriptedListening(mode: mode, language: language)
        }
    }
}

private final class ScriptedListening: VoiceListening {
    let mode: DemoChat.VoiceMode
    let language: Lang
    let partials: AsyncStream<String>

    init(mode: DemoChat.VoiceMode, language: Lang) {
        self.mode = mode
        self.language = language
        let words = DemoChat.heard(language)
        // The first words heard, and then it keeps listening until Stop.
        partials = AsyncStream { continuation in
            continuation.yield(words.split(separator: " ").prefix(3).joined(separator: " "))
        }
    }

    func stop() async throws -> String {
        switch mode {
        case .transcribing:
            // Holds on the transcribing step for the screenshot.
            try await Task.sleep(for: .seconds(3600))
            return ""
        case .failed:
            throw VoiceFailure.failed
        default:
            return DemoChat.heard(language)
        }
    }

    func cancel() async {}
}

#endif
