import DawriCore
import SwiftUI

/// Which field this is. Codes and addresses read left to right in both languages.
enum DSFieldKind {
    case plain, qid, code, address

    fileprivate var readsLeftToRight: Bool { self != .plain }
}

/// Label above the field, never a placeholder used as a label.
struct DSTextField: View {
    let label: String
    @Binding var text: String
    var hint: String?
    var error: String?
    var kind: DSFieldKind = .plain
    var placeholder: String?
    /// The composer shows only its placeholder. The label still reaches VoiceOver.
    var showsLabel = true

    @Environment(\.lang) private var lang
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            if showsLabel {
                Text(verbatim: label)
                    .dsText(.label)
                    .foregroundStyle(DS.Color.ink)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                field
                if let error {
                    Text(verbatim: error)
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.negative)
                }
                if let hint {
                    Text(verbatim: hint)
                        .dsText(.caption)
                        .foregroundStyle(DS.Color.muted)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return input
            .focused($focused)
            .dsText(.body, monoDigits: kind == .qid || kind == .code)
            .foregroundStyle(isEnabled ? DS.Color.ink : DS.Color.disabledText)
            .padding(.horizontal, DS.Space.m)
            .frame(minHeight: DS.Size.field)
            .background(isEnabled ? DS.Color.surface : DS.Color.raised, in: shape)
            .overlay {
                // An overlay, so the focused edge shifts nothing.
                if focused {
                    shape.strokeBorder(DS.Color.ink, lineWidth: DS.Stroke.focus)
                } else {
                    shape.strokeBorder(
                        error == nil ? DS.Color.control : DS.Color.negative, lineWidth: DS.Stroke.edge)
                }
            }
            .accessibilityHint(error.map { Text(verbatim: $0) } ?? Text(verbatim: ""))
    }

    @ViewBuilder
    private var input: some View {
        let base = TextField(
            label, text: $text,
            prompt: placeholder.map { Text(verbatim: $0).foregroundStyle(DS.Color.muted) } ?? Text(verbatim: ""))
        switch kind {
        case .plain:
            base
        case .qid:
            base
                .multilineTextAlignment(lang == .ar ? .trailing : .leading)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
        case .code:
            base
                .multilineTextAlignment(lang == .ar ? .trailing : .leading)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
                .onChange(of: text) { _, next in
                    let latin = latinDigits(next)
                    if latin != next { text = latin }
                }
        case .address:
            base
                .multilineTextAlignment(.leading)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .environment(\.layoutDirection, .leftToRight)
        }
    }
}

/// Eastern Arabic digits from an Arabic keyboard, as Latin ones.
func latinDigits(_ text: String) -> String {
    String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
        switch scalar.value {
        case 0x0660...0x0669: Unicode.Scalar(scalar.value - 0x0660 + 0x30) ?? scalar
        case 0x06F0...0x06F9: Unicode.Scalar(scalar.value - 0x06F0 + 0x30) ?? scalar
        default: scalar
        }
    }))
}
