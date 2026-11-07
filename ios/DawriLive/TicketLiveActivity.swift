import ActivityKit
import DawriCore
import SwiftUI
import WidgetKit

/// The placeholder ticket activity. It shows the number and stage in every presentation, and
/// nothing starts it yet. The real layouts are section 9 of iOS Design.md.
struct TicketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TicketActivityAttributes.self) { context in
            LockScreenView(state: context.state, lang: context.attributes.lang)
        } dynamicIsland: { context in
            let state = context.state
            let lang = context.attributes.lang
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    VStack(alignment: .leading, spacing: 2) {
                        TicketNumber(state: state, lang: lang)
                            .font(.title2.weight(.semibold).monospacedDigit())
                        StageName(state: state, lang: lang)
                            .font(.caption)
                    }
                    .foregroundStyle(IslandColor.hue)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    WaitText(state: state, lang: lang)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(IslandColor.ink)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(verbatim: Strings.bundled.translate(lang, "common.product"))
                        .font(.caption)
                        .foregroundStyle(IslandColor.muted)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(verbatim: Strings.bundled.translate(lang, "footer.demo"))
                        .font(.caption2)
                        .foregroundStyle(IslandColor.muted)
                }
            } compactLeading: {
                TicketNumber(state: state, lang: lang)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(IslandColor.hue)
            } compactTrailing: {
                WaitText(state: state, lang: lang)
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(IslandColor.ink)
            } minimal: {
                MinimalNumber(number: state.number)
            }
            .keylineTint(IslandColor.ink)
        }
    }
}

// The hex values of section 1 of iOS Design.md. The later phase reads them from DSPalette.

/// The Island is always black, so it always takes the dark values.
private enum IslandColor {
    static let ink = Color(hex: 0xF4F4F5)
    static let muted = Color(hex: 0xA6A7AC)
    static let hue = Color(hex: 0x689CE8)
}

/// The Lock Screen follows the phone's colour scheme.
private struct LockColor {
    let scheme: ColorScheme

    private func pick(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(hex: scheme == .dark ? dark : light)
    }

    var surface: Color { pick(0xFFFFFF, 0x1A1B1E) }
    var ink: Color { pick(0x0A0A0A, 0xF4F4F5) }
    var muted: Color { pick(0x6B6B6B, 0xA6A7AC) }
    var hue: Color { pick(0x1D5FBF, 0x689CE8) }
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

private struct LockScreenView: View {
    let state: TicketLiveState
    let lang: Lang

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let colors = LockColor(scheme: scheme)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TicketNumber(state: state, lang: lang)
                    .font(.system(size: 44, weight: .semibold).monospacedDigit())
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(colors.hue)
                Spacer()
                WaitText(state: state, lang: lang)
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(colors.ink)
            }
            StageName(state: state, lang: lang)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(colors.hue)
            Text(verbatim: Strings.bundled.translate(lang, "footer.demo"))
                .font(.caption2)
                .minimumScaleFactor(0.8)
                .foregroundStyle(colors.muted)
        }
        .lineLimit(1)
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .environment(\.layoutDirection, lang.dir == .rtl ? .rightToLeft : .leftToRight)
        .activityBackgroundTint(colors.surface)
        .activitySystemActionForegroundColor(colors.ink)
    }
}

private struct TicketNumber: View {
    let state: TicketLiveState
    let lang: Lang

    var body: some View {
        // A ticket number reads left to right in both languages.
        Text(verbatim: state.number ?? Strings.bundled.translate(lang, "ticket.nextStep"))
            .lineLimit(1)
            .contentTransition(.numericText())
    }
}

private struct StageName: View {
    let state: TicketLiveState
    let lang: Lang

    private var key: String? {
        switch state.stage {
        case .triage: "ticket.stepTriage"
        case .doctor: "ticket.stepDoctor"
        case .pharmacy: "ticket.stepPharmacy"
        default: nil
        }
    }

    var body: some View {
        Text(verbatim: key.map { Strings.bundled.translate(lang, $0) } ?? "–")
            .lineLimit(1)
    }
}

/// `12 min`, or a dash for a missing wait. A real zero prints as zero.
private struct WaitText: View {
    let state: TicketLiveState
    let lang: Lang

    var body: some View {
        Text(verbatim: state.estWaitMin.map { "\($0) \(lang == .ar ? "د" : "min")" } ?? "–")
            .lineLimit(1)
    }
}

/// The last three digits, or a clock when there is no number.
private struct MinimalNumber: View {
    let number: String?

    var body: some View {
        if let number {
            Text(verbatim: String(number.suffix(3)))
                .font(.caption2.weight(.semibold).monospacedDigit())
                .foregroundStyle(IslandColor.hue)
        } else {
            Image(systemName: "clock")
                .foregroundStyle(IslandColor.ink)
        }
    }
}
