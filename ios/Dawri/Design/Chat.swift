import DawriCore
import SwiftUI

private let bubbleShape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)

/// No tails, avatars or timestamps. The assistant is on the leading side, the patient on the
/// trailing side, and each bubble's text keeps its own direction.
struct ChatBubble: View {
    let role: ChatRole
    let text: String

    var body: some View {
        let isUser = role == .user
        Text(verbatim: Bidi.auto(text))
            .dsText(.body)
            .foregroundStyle(isUser ? DS.Color.primaryText : DS.Color.ink)
            .multilineTextAlignment(.leading)
            .padding(.vertical, DS.Space.s)
            .padding(.horizontal, DS.Space.m)
            .background(isUser ? DS.Color.primaryFill : DS.Color.surface, in: bubbleShape)
            .overlay {
                if !isUser {
                    bubbleShape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.edge)
                }
            }
            .containerRelativeFrame(.horizontal, alignment: isUser ? .trailing : .leading) { width, _ in
                width * 0.85
            }
            .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: Bidi.strip(text)))
            .accessibilityIdentifier("bubble")
    }
}

/// Static words, no dots animation, announced politely.
struct ThinkingBubble: View {
    @Environment(\.lang) private var lang

    var body: some View {
        Text(verbatim: lang.t("chat.thinking"))
            .dsText(.body)
            .foregroundStyle(DS.Color.muted)
            .padding(.vertical, DS.Space.s)
            .padding(.horizontal, DS.Space.m)
            .background(DS.Color.surface, in: bubbleShape)
            .overlay(bubbleShape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.edge))
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("chat-thinking")
            .onAppear {
                var message = AttributedString(lang.t("chat.thinking"))
                message.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(message).post()
            }
    }
}

/// The read-back at the end of the chat. Words not yet sent disable Yes, because the rules read
/// only what is sent, and the card says what to do. A failed Yes shows in place, with a Retry
/// only while nothing is held back.
struct SummaryCard: View {
    let service: Service
    /// The read-back without its closing question, which the card asks itself.
    let summary: String
    var hasUnsent = false
    var isThinking = false
    var isConfirming = false
    var confirmError: String?
    let onYes: () -> Void
    let onChange: () -> Void

    @Environment(\.lang) private var lang

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Pill(lang.t("chat.service.\(service.rawValue)"), tone: .neutral)
                Text(verbatim: Bidi.auto(summary))
                    .dsText(.body)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: Bidi.strip(summary)))
                    .accessibilityIdentifier("chat-summary-text")
                Text(verbatim: lang.t("chat.summary.check"))
                    .dsText(.section)
                    .foregroundStyle(DS.Color.ink)
                    .accessibilityAddTraits(.isHeader)
                if let confirmError {
                    ErrorBlock(message: confirmError, retry: hasUnsent ? nil : onYes)
                        .accessibilityIdentifier("chat-confirm-error")
                }
                if hasUnsent {
                    Text(verbatim: lang.t("chat.summary.unsent"))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.warning)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("chat-summary-unsent")
                        .onAppear {
                            AccessibilityNotification.Announcement(lang.t("chat.summary.unsent")).post()
                        }
                }
                VStack(spacing: DS.Space.s) {
                    Button(lang.t("chat.summary.yes"), action: onYes)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(isThinking || hasUnsent)
                        .dsLoading(isConfirming)
                        .accessibilityIdentifier("chat-summary-yes")
                    Button(lang.t("chat.summary.change"), action: onChange)
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(isConfirming)
                        .accessibilityIdentifier("chat-summary-change")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-summary")
    }
}

/// The chat's text field: the `DSTextField` look, growing with its text, with focus the screen
/// can move. `isReadOnly` keeps the look and the keyboard but drops edits, as the web's
/// `readOnly` does while a turn is out.
struct ChatField: View {
    let label: String
    @Binding var text: String
    var placeholder: String?
    var isReadOnly = false
    var lines: ClosedRange<Int> = 1...5
    var focus: FocusState<Bool>.Binding

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        TextField(
            label,
            text: Binding(
                get: { text },
                set: { next in if !isReadOnly { text = next } }),
            prompt: placeholder.map { Text(verbatim: $0).foregroundStyle(DS.Color.muted) },
            axis: .vertical
        )
        .lineLimit(lines)
        .focused(focus)
        .dsText(.body)
        .foregroundStyle(DS.Color.ink)
        .multilineTextAlignment(.leading)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.m)
        .frame(maxWidth: .infinity, minHeight: DS.Size.field, alignment: .leading)
        .background(DS.Color.surface, in: shape)
        .overlay {
            // An overlay, so the focused edge shifts nothing.
            if focus.wrappedValue {
                shape.strokeBorder(DS.Color.ink, lineWidth: DS.Stroke.focus)
            } else {
                shape.strokeBorder(DS.Color.control, lineWidth: DS.Stroke.edge)
            }
        }
        .accessibilityLabel(Text(verbatim: label))
    }
}

/// What sits under the field in the composer.
enum ComposerVoice: Equatable {
    /// The mic button, `secondary` once the box has text or the summary has the primary.
    case mic(secondary: Bool, disabled: Bool)
    /// The microphone is open.
    case listening(seconds: Int, partial: String)
    /// `voice.starting` or `voice.transcribing`, with a spinner.
    case working(key: String)
}

/// The bottom of the chat. `ground` fill, a 1 pt edge on top. One primary at a time: the mic
/// while the box is empty, Send once it has text, Stop while listening. In accessibility sizes
/// the field and Send stack. Voice errors sit above the field.
struct Composer: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    /// A turn or a confirm is out: the field keeps its words and takes no edits.
    var isReadOnly = false
    /// Nothing may be sent: a turn is out, a confirm is out, or the microphone is busy.
    var isBusy = false
    var voiceError: String?
    var voice = ComposerVoice.mic(secondary: false, disabled: false)
    let onSend: () -> Void
    let onMic: () -> Void
    var onStop: () -> Void = {}

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasText: Bool { !ChatRules.isBlank(text) }

    var body: some View {
        VStack(spacing: DS.Space.s) {
            if let voiceError {
                Text(verbatim: voiceError)
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.negative)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("voice-error")
                    .onAppear { AccessibilityNotification.Announcement(voiceError).post() }
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: DS.Space.s))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: DS.Space.s))
            layout {
                ChatField(
                    label: lang.t("chat.input.label"), text: $text,
                    placeholder: lang.t("chat.input.placeholder"), isReadOnly: isReadOnly,
                    lines: typeSize.isAccessibilitySize ? 1...3 : 1...5, focus: focus)
                    .accessibilityIdentifier("chat-input")
                sendButton
            }
            voiceControl
                .transition(panelTransition)
        }
        .animation(DS.Motion.resolved(DS.Motion.sheet, reduceMotion: reduceMotion), value: voice)
        .composerShell()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chat-composer")
    }

    /// Panels rise along the path they leave by. Reduce Motion cross-fades.
    private var panelTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    @ViewBuilder
    private var sendButton: some View {
        let send = Button(action: onSend) {
            Label {
                Text(verbatim: lang.t("chat.send"))
            } icon: {
                Image(systemName: "arrow.up")
            }
            .labelStyle(.titleAndIcon)
        }
        .disabled(!hasText || isBusy)
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
        .accessibilityIdentifier("chat-send")
        if hasText {
            send.buttonStyle(PrimaryButtonStyle())
        } else {
            send.buttonStyle(SecondaryButtonStyle())
        }
    }

    @ViewBuilder
    private var voiceControl: some View {
        switch voice {
        case .mic(let secondary, let disabled):
            let mic = Button(action: onMic) {
                Label {
                    Text(verbatim: lang.t("voice.start"))
                } icon: {
                    Image(systemName: "mic.fill")
                }
                .labelStyle(.titleAndIcon)
                .frame(minHeight: DS.Size.buttonLarge - DS.Space.s * 2)
            }
            .disabled(disabled)
            .accessibilityIdentifier("chat-mic")
            if secondary {
                mic.buttonStyle(SecondaryButtonStyle())
            } else {
                mic.buttonStyle(PrimaryButtonStyle())
            }
        case .listening(let seconds, let partial):
            ListeningPanel(elapsedSeconds: seconds, transcript: partial, onStop: onStop)
        case .working(let key):
            VoiceWorking(key: key)
        }
    }
}

extension View {
    /// The composer's band: `ground`, a hairline on top, padding 12 and 16.
    func composerShell() -> some View {
        padding(.vertical, DS.Space.m)
            .padding(.horizontal, DS.Space.l)
            .background(DS.Color.ground)
            .overlay(alignment: .top) {
                DS.Color.hairline.frame(height: DS.Stroke.edge)
            }
    }
}

/// While the microphone is open. The dot does not pulse, and the panel is a live region.
struct ListeningPanel: View {
    let elapsedSeconds: Int
    let transcript: String
    let onStop: () -> Void

    @Environment(\.lang) private var lang

    var body: some View {
        let clock = ChatRules.clock(elapsedSeconds)
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Circle().fill(DS.Color.ink)
                    .frame(width: DS.Space.s, height: DS.Space.s)
                    .accessibilityHidden(true)
                Text(verbatim: lang.t("voice.listening"))
                    .dsText(.bodyStrong)
                    .foregroundStyle(DS.Color.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                // A clock reads left to right as a unit, and jumps: no animation.
                Text(verbatim: clock)
                    .dsText(.body, monoDigits: true)
                    .foregroundStyle(DS.Color.ink)
                    .contentTransition(.identity)
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityIdentifier("voice-timer")
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.updatesFrequently)
            if !transcript.isEmpty {
                Text(verbatim: Bidi.auto(transcript))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: Bidi.strip(transcript)))
                    .accessibilityIdentifier("voice-partial")
            }
            Button(action: onStop) {
                Label {
                    Text(verbatim: lang.t("voice.stop"))
                } icon: {
                    Image(systemName: "stop.fill")
                }
                .labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("voice-stop")
        }
        .padding(DS.Space.m)
        .background(DS.Color.surface, in: shape)
        .overlay(shape.strokeBorder(DS.Color.control, lineWidth: DS.Stroke.edge))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-listening")
    }
}

/// `voice.starting` and `voice.transcribing`: on the phone these are brief.
struct VoiceWorking: View {
    let key: String

    @Environment(\.lang) private var lang

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: DS.Space.s) {
            ProgressView().tint(DS.Color.muted)
            Text(verbatim: lang.t(key))
                .dsText(.body)
                .foregroundStyle(DS.Color.muted)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: .infinity, minHeight: DS.Size.buttonLarge)
        .background(DS.Color.surface, in: shape)
        .overlay(shape.strokeBorder(DS.Color.control, lineWidth: DS.Stroke.edge))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("voice-working")
    }
}

/// Nothing is sent until the patient taps Send. The words are only what the phone heard, and
/// they can be fixed here first.
struct TranscriptConfirmPanel: View {
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var isBusy = false
    let onSend: () -> Void
    let onRetry: () -> Void
    let onClear: () -> Void

    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text(verbatim: lang.t("voice.confirm.check"))
                .dsText(.section)
                .foregroundStyle(DS.Color.ink)
                .accessibilityAddTraits(.isHeader)
            ChatField(
                label: lang.t("voice.confirm.check"), text: $text, lines: 3...6, focus: focus)
                .accessibilityIdentifier("voice-transcript")
            Button(lang.t("voice.confirm.send"), action: onSend)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(ChatRules.isBlank(text) || isBusy)
                .accessibilityIdentifier("voice-send")
            HStack(spacing: DS.Space.m) {
                Button(lang.t("voice.confirm.retry"), action: onRetry)
                    .accessibilityIdentifier("voice-retry")
                Spacer(minLength: DS.Space.m)
                Button(lang.t("voice.confirm.clear"), action: onClear)
                    .accessibilityIdentifier("voice-clear")
            }
            .buttonStyle(QuietButtonStyle())
        }
        .composerShell()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("voice-confirm")
    }
}
