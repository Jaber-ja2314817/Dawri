import DawriCore
import SwiftUI

/// `surface` with a 1 pt edge and no shadow. `flush` drops the padding for rows.
struct Card<Content: View>: View {
    var flush = false
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        content
            .padding(flush ? 0 : DS.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.surface, in: shape)
            .overlay(shape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.edge))
            .clipShape(shape)
    }
}

/// The 1 pt rule above a row, text edge to text edge. The first row of a card has none.
private struct RowRule: View {
    var body: some View {
        DS.Color.rule
            .frame(height: DS.Stroke.edge)
            .padding(.horizontal, DS.Space.l)
    }
}

/// A row in a flush card. `showsRule` is false on the first row.
struct ListRow: View {
    let title: String
    var subtitle: String?
    var pill: Pill?
    var showsChevron = true
    var showsRule = true

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: 0) {
            if showsRule { RowRule() }
            HStack(spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: DS.Space.xxs) {
                    Text(verbatim: title)
                        .dsText(.bodyStrong)
                        .foregroundStyle(DS.Color.ink)
                    if let subtitle {
                        Text(verbatim: subtitle)
                            .dsText(.secondary)
                            .foregroundStyle(DS.Color.muted)
                    }
                    if typeSize.isAccessibilitySize, let pill {
                        pill.padding(.top, DS.Space.xs)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .multilineTextAlignment(.leading)
                if !typeSize.isAccessibilitySize, let pill {
                    pill
                }
                if showsChevron {
                    Image(systemName: "chevron.forward")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(DS.Color.muted)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.m)
            .frame(minHeight: DS.Size.rowTwoLine)
        }
        .contentShape(Rectangle())
    }
}

/// Fills a tappable `ListRow` with `raised` while pressed.
struct ListRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? DS.Color.raised : Color.clear)
    }
}

enum KeyValueStyle {
    /// S03 values.
    case label
    /// S10 and S08 values.
    case stat

    fileprivate var role: DS.TextRole { self == .label ? .label : .statValue }
}

/// A label and a value, with numbers ending on one trailing edge.
struct KeyValueRow<Value: View>: View {
    let label: String
    let style: KeyValueStyle
    let showsRule: Bool
    @ViewBuilder var value: Value

    @Environment(\.dynamicTypeSize) private var typeSize

    init(
        label: String, style: KeyValueStyle = .label, showsRule: Bool = true,
        @ViewBuilder value: () -> Value
    ) {
        self.label = label
        self.style = style
        self.showsRule = showsRule
        self.value = value()
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsRule { RowRule() }
            Group {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        labelText
                        valueText
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack(spacing: DS.Space.m) {
                        labelText
                        Spacer(minLength: DS.Space.s)
                        valueText
                    }
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.s)
            .frame(minHeight: DS.Size.row)
        }
        .accessibilityElement(children: .combine)
    }

    private var labelText: some View {
        Text(verbatim: label)
            .dsText(.secondary)
            .foregroundStyle(DS.Color.muted)
    }

    private var valueText: some View {
        value
            .dsText(style.role)
            .foregroundStyle(DS.Color.ink)
    }
}

extension KeyValueRow where Value == Text {
    init(label: String, value: String, style: KeyValueStyle = .label, showsRule: Bool = true) {
        self.init(label: label, style: style, showsRule: showsRule) { Text(verbatim: value) }
    }
}

enum PillTone {
    case positive, negative, warning, neutral

    fileprivate var fill: Color {
        switch self {
        case .positive: DS.Color.pillPositiveFill
        case .negative: DS.Color.pillNegativeFill
        case .warning: DS.Color.pillWarningFill
        case .neutral: DS.Color.pillNeutralFill
        }
    }

    fileprivate var text: Color {
        switch self {
        case .positive: DS.Color.pillPositiveText
        case .negative: DS.Color.pillNegativeText
        case .warning: DS.Color.pillWarningText
        case .neutral: DS.Color.pillNeutralText
        }
    }
}

/// Never squeezed. Beside a value, never above a heading.
struct Pill: View {
    let text: String
    let tone: PillTone

    init(_ text: String, tone: PillTone) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(verbatim: text)
            .dsText(.pill)
            .foregroundStyle(tone.text)
            .padding(.vertical, DS.Space.xxs)
            .padding(.horizontal, DS.Space.s)
            .frame(minHeight: 24)
            .background(tone.fill, in: Capsule())
            .fixedSize()
    }
}

struct Notice: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        Text(verbatim: text)
            .dsText(.secondary)
            .foregroundStyle(DS.Color.noticeText)
            .multilineTextAlignment(.leading)
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DS.Color.noticeFill, in: shape)
            .overlay(shape.strokeBorder(DS.Color.noticeEdge, lineWidth: DS.Stroke.edge))
    }
}

/// The first item of a screen's content, with the header trait.
struct ScreenTitle: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(verbatim: text)
            .dsText(.screenTitle)
            .foregroundStyle(DS.Color.ink)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}
