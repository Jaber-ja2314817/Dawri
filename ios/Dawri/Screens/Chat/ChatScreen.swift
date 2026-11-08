import DawriCore
import SwiftUI

/// S05. What brings you in, one question at a time? The port of
/// frontend/src/features/chat/ChatScreen.tsx over the visit's `ChatModel` and `VoiceModel`, which
/// live on `AppModel`: leaving this screen ends nothing, and the draft survives anything short of
/// signing out. Every message passes the clinic's rules before anything else, and a red flag
/// opens S06 from wherever the patient is.
struct ChatScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model

    var body: some View {
        ChatContent(
            visit: visit, watcher: watcher, chat: model.chat(for: visit),
            voice: model.voice(for: visit.visitId))
    }
}

/// What the scroll follows: each change the web's effect names, plus the language, so a switch
/// returns to the newest message, and what makes the summary card grow, so its Yes and Change
/// never sit behind the composer.
private struct NewestKey: Equatable {
    var messages: Int
    var thinking: Bool
    var summary: Bool
    var failure: Bool
    var voice: VoiceStep
    var lang: Lang
    var confirmError: Bool
    var unsent: Bool
}

private struct ChatContent: View {
    let visit: Visit
    let watcher: VisitWatcher
    let chat: ChatModel
    let voice: VoiceModel

    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var fieldFocused: Bool
    @FocusState private var transcriptFocused: Bool
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var attachment: Int?
    @State private var changeTaps = 0

    private var busy: Bool {
        chat.thinking || chat.confirming || voice.step != .idle
    }

    var body: some View {
        let messages = chat.messages(in: visit)
        let summary = chat.summary(in: visit)
        let unsent = ChatRules.hasUnsentWords(
            draft: chat.draft, voiceStep: voice.step, transcript: voice.transcript)
        PatientScaffold(title: lang.t("screen.chat"), footer: .pinned, scrollPosition: $position) {
            transcript(messages: messages, summary: summary, unsent: unsent)
        } pinnedBottom: {
            composer(summary: summary)
        }
        .sensoryFeedback(DS.Haptic.sent, trigger: chat.sentCount)
        .sensoryFeedback(DS.Haptic.micStart, trigger: voice.step) { _, new in new == .starting }
        .sensoryFeedback(DS.Haptic.micStop, trigger: voice.step) { old, _ in old == .transcribing }
        .sensoryFeedback(DS.Haptic.select, trigger: changeTaps)
        .onChange(of: NewestKey(
            messages: messages.count, thinking: chat.thinking, summary: summary != nil,
            failure: chat.failure != nil, voice: voice.step, lang: lang,
            confirmError: chat.confirmError != nil, unsent: unsent)
        ) {
            scrollToNewest()
        }
        .onChange(of: visit) { _, next in chat.sync(next) }
        .onChange(of: lang) { _, next in
            Task { await voice.languageChanged(to: next) }
        }
        .onChange(of: voice.error) { _, error in
            if error != nil { fieldFocused = true }
        }
        .onAppear {
            attachment = chat.attach { [watcher] in
                await watcher.refetch()
                return watcher.visit
            }
            chat.sync(visit)
            Task { await voice.languageChanged(to: lang) }
        }
        .onDisappear {
            chat.detach(attachment)
            // The microphone never stays open behind another screen.
            Task { await voice.leave() }
        }
        #if DEBUG
        .task { await DemoChat.act(chat: chat, voice: voice) }
        #endif
    }

    // The transcript

    private func transcript(messages: [ChatMessage], summary: ChatSummary?, unsent: Bool) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            ForEach(Array(messages.enumerated()), id: \.offset) { index, message in
                // The closing summary, which its card shows instead.
                if index != summary?.index {
                    ChatBubble(role: message.role, text: message.content)
                        .transition(arrival)
                }
            }
            if let summary {
                SummaryCard(
                    service: summary.service,
                    summary: ChatRules.withoutClosingQuestion(summary.text),
                    hasUnsent: unsent, isThinking: chat.thinking, isConfirming: chat.confirming,
                    confirmError: chat.confirmError.map {
                        errorText($0, strings: .bundled, lang: lang)
                    },
                    onYes: { Task { await chat.confirm(unsentWords: unsent) } },
                    onChange: {
                        voice.clearError()
                        fieldFocused = true
                        changeTaps += 1
                    })
                .transition(arrival)
            }
            if chat.thinking {
                ThinkingBubble()
            }
            if let failure = chat.failure {
                ErrorBlock(
                    message: failure.timedOut
                        ? lang.t("chat.timeout")
                        : errorText(failure.error, strings: .bundled, lang: lang),
                    retry: failure.retry ? { Task { await chat.retry() } } : nil)
                .accessibilityIdentifier("chat-error")
            }
        }
        .animation(DS.Motion.resolved(DS.Motion.number, reduceMotion: reduceMotion), value: messages.count)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: lang.t("chat.log")))
        .accessibilityIdentifier("screen-chat")
    }

    /// A new bubble rises 8 pt as it fades in. Reduce Motion keeps only the fade.
    private var arrival: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: DS.Space.s))
    }

    private func scrollToNewest() {
        if reduceMotion {
            position.scrollTo(edge: .bottom)
        } else {
            withAnimation(DS.Motion.number) { position.scrollTo(edge: .bottom) }
        }
    }

    // The composer

    @ViewBuilder
    private func composer(summary: ChatSummary?) -> some View {
        Group {
            if voice.step == .confirm {
                TranscriptConfirmPanel(
                    text: Binding(get: { voice.transcript }, set: { voice.setTranscript($0) }),
                    focus: $transcriptFocused, isBusy: chat.thinking || chat.confirming,
                    onSend: sendTranscript,
                    onRetry: { Task { await voice.start() } },
                    onClear: { voice.reset() })
                .transition(panel)
            } else {
                Composer(
                    text: Binding(
                        get: { chat.draft },
                        set: { next in
                            // A field gaining focus can write back the same text, which is not
                            // typing, so it leaves a voice error on screen.
                            guard next != chat.draft else { return }
                            chat.setDraft(next)
                            voice.clearError()
                        }),
                    focus: $fieldFocused,
                    isReadOnly: chat.thinking || chat.confirming,
                    isBusy: busy,
                    voiceError: voice.error.map { lang.t($0.textKey) },
                    voice: composerVoice(summary: summary),
                    onSend: submit,
                    onMic: { Task { await voice.start() } },
                    onStop: { Task { await voice.stop() } })
                .transition(panel)
            }
        }
        .animation(DS.Motion.resolved(DS.Motion.sheet, reduceMotion: reduceMotion), value: voice.step == .confirm)
    }

    private var panel: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    private func composerVoice(summary: ChatSummary?) -> ComposerVoice {
        switch voice.step {
        case .listening:
            .listening(seconds: voice.seconds, partial: voice.partial)
        case .starting:
            .working(key: "voice.starting")
        case .transcribing:
            .working(key: "voice.transcribing")
        case .idle, .confirm:
            .mic(
                secondary: !ChatRules.isBlank(chat.draft) || summary != nil,
                disabled: chat.thinking || chat.confirming)
        }
    }

    private func submit() {
        guard !busy else { return }
        Task { await chat.submit() }
    }

    /// The transcript goes as it stands in the field. The box keeps whatever is typed in it.
    private func sendTranscript() {
        let words = voice.transcript
        Task { await chat.sendText(words) }
        voice.reset()
    }
}
