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
            .accessibilityLabel(Text(verbatim: text))
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
            .onAppear {
                var message = AttributedString(lang.t("chat.thinking"))
                message.accessibilitySpeechAnnouncementPriority = .low
                AccessibilityNotification.Announcement(message).post()
            }
    }
}

/// The read-back at the end of the chat. Unsent text in the box disables Yes, because the rules
/// read only what is sent.
struct SummaryCard: View {
    let service: Service
    let summary: String
    var hasUnsent = false
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
                Text(verbatim: lang.t("chat.summary.check"))
                    .dsText(.section)
                    .foregroundStyle(DS.Color.ink)
                if hasUnsent {
                    Text(verbatim: lang.t("chat.summary.unsent"))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.warning)
                }
                Button(lang.t("chat.summary.yes"), action: onYes)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(hasUnsent)
                Button(lang.t("chat.summary.change"), action: onChange)
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
    }
}

/// The bottom of the chat. `ground` fill, a 1 pt edge on top. One primary at a time: the mic
/// while the box is empty, Send once it has text.
struct Composer: View {
    @Binding var text: String
    var isBusy = false
    var error: String?
    let onSend: () -> Void
    let onMic: () -> Void

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    private var isEmpty: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(spacing: DS.Space.m) {
            if let error {
                Text(verbatim: error)
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.negative)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: DS.Space.s))
                : AnyLayout(HStackLayout(alignment: .bottom, spacing: DS.Space.s))
            layout {
                DSTextField(
                    label: lang.t("chat.input.label"), text: $text,
                    placeholder: lang.t("chat.input.placeholder"), showsLabel: false)
                sendButton
            }
            micButton
        }
        .disabled(isBusy)
        .composerShell()
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
        .disabled(isEmpty)
        .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
        if isEmpty {
            send.buttonStyle(SecondaryButtonStyle())
        } else {
            send.buttonStyle(PrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private var micButton: some View {
        let mic = Button(action: onMic) {
            Label {
                Text(verbatim: lang.t("voice.start"))
            } icon: {
                Image(systemName: "mic.fill")
            }
            .labelStyle(.titleAndIcon)
            .frame(minHeight: DS.Size.buttonLarge - DS.Space.s * 2)
        }
        if isEmpty {
            mic.buttonStyle(PrimaryButtonStyle())
        } else {
            mic.buttonStyle(SecondaryButtonStyle())
        }
    }
}

private extension View {
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
        let clock = "\(elapsedSeconds / 60):\(String(format: "%02d", elapsedSeconds % 60))"
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(spacing: DS.Space.s) {
                    Circle().fill(DS.Color.ink)
                        .frame(width: DS.Space.s, height: DS.Space.s)
                        .accessibilityHidden(true)
                    Text(verbatim: lang.t("voice.listening"))
                        .dsText(.bodyStrong)
                        .foregroundStyle(DS.Color.ink)
                    Spacer(minLength: DS.Space.s)
                    Text(verbatim: clock)
                        .dsText(.secondary, monoDigits: true)
                        .foregroundStyle(DS.Color.muted)
                        .environment(\.layoutDirection, .leftToRight)
                }
                if !transcript.isEmpty {
                    Text(verbatim: Bidi.auto(transcript))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.ink)
                        .multilineTextAlignment(.leading)
                }
                Button(lang.t("voice.stop"), action: onStop)
                    .buttonStyle(PrimaryButtonStyle())
            }
        }
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Nothing is sent until the patient taps Send.
struct TranscriptConfirmPanel: View {
    @Binding var text: String
    let onSend: () -> Void
    let onRetry: () -> Void
    let onClear: () -> Void

    @Environment(\.lang) private var lang

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(verbatim: lang.t("voice.confirm.check"))
                    .dsText(.section)
                    .foregroundStyle(DS.Color.ink)
                DSTextField(label: lang.t("chat.input.label"), text: $text)
                Button(lang.t("voice.confirm.send"), action: onSend)
                    .buttonStyle(PrimaryButtonStyle())
                HStack {
                    Button(lang.t("voice.confirm.retry"), action: onRetry)
                    Spacer(minLength: DS.Space.m)
                    Button(lang.t("voice.confirm.clear"), action: onClear)
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
    }
}
