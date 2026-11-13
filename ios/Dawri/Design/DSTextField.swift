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
    /// The web's field id. The field takes it, and its error takes it with `-error` after.
    var identifier: String?

    @Environment(\.lang) private var lang
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dynamicTypeSize) private var typeSize
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
                    // Their whole height, so a crowded column cannot cut them to one line.
                    Text(verbatim: error)
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.negative)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(identifier.map { "\($0)-error" } ?? "")
                } else if let hint {
                    // As on the web, an error takes the hint's place.
                    Text(verbatim: hint)
                        .dsText(.caption)
                        .foregroundStyle(DS.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var field: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        return input
            // The wrapping address field binds its own focus inside, on the field itself.
            .modifier(FocusBinding(focused: $focused, applies: !wrapsAddress))
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
            .accessibilityIdentifier(identifier ?? "")
    }

    /// The address at accessibility sizes, which wraps.
    private var wrapsAddress: Bool { kind == .address && typeSize.isAccessibilitySize }

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
                .onChange(of: text) { _, next in
                    let latin = latinDigits(next)
                    if latin != next { text = latin }
                }
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
        case .address where typeSize.isAccessibilitySize:
            // A long address wraps at accessibility sizes instead of ending in an ellipsis
            // (iOS Design section 11, check 8). An address never holds a line break, so Return
            // only closes the keyboard here, and Connect stays the way to connect.
            // The field's own prompt stays on one line even on a vertical field, so the sample
            // address ended in an ellipsis at AX3. Here the sample is its own wrapping text,
            // drawn behind the empty field, and a tap anywhere on the box focuses the field.
            ZStack(alignment: .topLeading) {
                if text.isEmpty, let placeholder {
                    Text(verbatim: placeholder)
                        .foregroundStyle(DS.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityHidden(true)
                }
                TextField(label, text: $text, prompt: Text(verbatim: ""), axis: .vertical)
                    .lineLimit(1...4)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .multilineTextAlignment(.leading)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($focused)
                    .onChange(of: text) { _, next in
                        guard next.contains(where: \.isNewline) else { return }
                        text = next.filter { !$0.isNewline }
                        focused = false
                    }
            }
            .padding(.vertical, DS.Space.s)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
            .environment(\.layoutDirection, .leftToRight)
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

/// `.focused` where the input is the field itself, and nothing where the input binds its own.
private struct FocusBinding: ViewModifier {
    var focused: FocusState<Bool>.Binding
    let applies: Bool

    func body(content: Content) -> some View {
        if applies {
            content.focused(focused)
        } else {
            content
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
