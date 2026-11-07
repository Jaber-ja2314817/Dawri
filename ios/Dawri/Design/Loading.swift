import DawriCore
import SwiftUI

/// Flat and still. Sized as what will land, and hidden from VoiceOver.
struct SkeletonBar: View {
    var width: CGFloat?
    var height: CGFloat = 20

    var body: some View {
        let radius = height > 56 ? DS.Radius.card : DS.Radius.control
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(DS.Color.skeleton)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .accessibilityHidden(true)
    }
}

/// Inside the block that failed, never full screen, and never a red fill.
struct ErrorBlock: View {
    let message: String
    let retry: (() -> Void)?

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    init(message: String, retry: (() -> Void)? = nil) {
        self.message = message
        self.retry = retry
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.m))
        layout {
            Text(verbatim: message)
                .dsText(.secondary)
                .foregroundStyle(DS.Color.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let retry {
                Button(lang.t("common.retry"), action: retry)
                    .buttonStyle(QuietButtonStyle(underlined: true))
            }
        }
        .padding(.vertical, DS.Space.m)
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Color.surface, in: shape)
        .overlay(shape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.edge))
        .accessibilityElement(children: .contain)
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// A missing value, as opposed to a real zero. Takes its size from the surrounding role.
struct Dash: View {
    @Environment(\.lang) private var lang

    var body: some View {
        Text(verbatim: "–")
            .foregroundStyle(DS.Color.muted)
            .accessibilityLabel(Text(verbatim: lang.t("ticket.notKnown")))
    }
}

/// The figure keeps its own direction and the unit follows the language. A nil value is a dash.
struct Measure: View {
    let value: Double?
    let unit: String

    init(value: Int?, unit: String) {
        self.value = value.map(Double.init)
        self.unit = unit
    }

    init(value: Double?, unit: String) {
        self.value = value
        self.unit = unit
    }

    var body: some View {
        if let value {
            let figure = value == value.rounded() ? String(Int(value)) : String(value)
            Text(verbatim: "\(Bidi.ltr(figure)) \(unit)")
                .lineLimit(1)
                .fixedSize()
                .accessibilityLabel(Text(verbatim: "\(figure) \(unit)"))
        } else {
            Dash()
        }
    }
}
