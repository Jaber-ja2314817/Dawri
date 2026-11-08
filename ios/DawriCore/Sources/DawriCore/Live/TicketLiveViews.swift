import SwiftUI

// The Live Activity's layouts, iOS Design section 9, as plain SwiftUI. Nothing here needs
// ActivityKit or UIKit, so the package still builds for macOS, the widget extension wraps these
// in its `ActivityConfiguration`, and the DEBUG gallery in the app renders the same views.
//
// The extension does not know the app's language, so every view takes the activity's own and
// sets the layout direction and locale from it. The Island is always black, so it always takes
// the dark values. The Lock Screen follows the phone's scheme. The hue goes only on the number
// and the current stage.

// MARK: Colours

/// The section 1 tokens the Live views use, resolved from `DSPalette` for one scheme.
public struct TicketLiveColors: Sendable {
    public let surface: Color
    public let ink: Color
    public let muted: Color
    public let hue: Color
    public let control: Color

    public init(dark: Bool, increasedContrast: Bool = false) {
        func pick(_ hex: DSHex) -> Color {
            let value = dark
                ? (increasedContrast ? hex.darkHigh : hex.dark)
                : (increasedContrast ? hex.lightHigh : hex.light)
            return Color(
                .sRGB,
                red: Double((value >> 16) & 0xff) / 255,
                green: Double((value >> 8) & 0xff) / 255,
                blue: Double(value & 0xff) / 255)
        }
        surface = pick(DSPalette.surface)
        ink = pick(DSPalette.ink)
        muted = pick(DSPalette.muted)
        hue = pick(DSPalette.hue)
        control = pick(DSPalette.control)
    }

    /// The Island's values: always the dark ones, because the Island is always black.
    public static func island(increasedContrast: Bool = false) -> TicketLiveColors {
        TicketLiveColors(dark: true, increasedContrast: increasedContrast)
    }

    /// The Lock Screen's values, which follow the phone's scheme.
    public static func lockScreen(
        _ scheme: ColorScheme, contrast: ColorSchemeContrast = .standard
    ) -> TicketLiveColors {
        TicketLiveColors(dark: scheme == .dark, increasedContrast: contrast == .increased)
    }
}

// MARK: Text

/// Every text the Live views show, in the activity's language. Numbers and figures are wrapped
/// in a left-to-right isolate, and `spoken` strips the isolates for VoiceOver.
public enum TicketLiveText {
    private static let isolates: Set<Unicode.Scalar> = ["\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]

    static func ltr(_ text: String) -> String { "\u{2066}\(text)\u{2069}" }
    static func auto(_ text: String) -> String { "\u{2068}\(text)\u{2069}" }

    public static func strip(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isolates.contains($0) }))
    }

    static func t(_ lang: Lang, _ key: String, _ vars: Strings.Vars? = nil) -> String {
        Strings.bundled.translate(lang, key, vars)
    }

    /// The number, isolated, so `T-014` reads left to right in Arabic too.
    public static func number(_ state: TicketLiveState) -> String? {
        state.number.map(ltr)
    }

    /// The last three digits, for the minimal presentation: `014`.
    public static func minimalNumber(_ state: TicketLiveState) -> String? {
        state.number.map { ltr(String($0.suffix(3))) }
    }

    public static func stageKey(_ stage: VisitStage) -> String? {
        switch stage {
        case .triage: "ticket.stepTriage"
        case .doctor: "ticket.stepDoctor"
        case .pharmacy: "ticket.stepPharmacy"
        default: nil
        }
    }

    public static func stageName(_ state: TicketLiveState, lang: Lang) -> String? {
        stageKey(state.stage).map { t(lang, $0) }
    }

    /// `12 min`, with the figure isolated and the unit in the language: `12 د`. A dash when the
    /// wait is not known. A real zero prints as zero.
    public static func wait(_ state: TicketLiveState, lang: Lang) -> String {
        guard let minutes = state.estWaitMin else { return "–" }
        return "\(ltr(String(minutes))) \(t(lang, "centre.unitMin"))"
    }

    public static func ahead(_ state: TicketLiveState, lang: Lang) -> String {
        t(lang, "live.ahead", ["count": state.peopleAhead.map { ltr(String($0)) } ?? "–"])
    }

    public static func peopleAhead(_ state: TicketLiveState) -> String {
        state.peopleAhead.map { ltr(String($0)) } ?? "–"
    }

    public static func goNow(_ state: TicketLiveState, lang: Lang) -> String {
        t(lang, "ticket.goNow", ["counter": auto(state.counter)])
    }

    /// Compact trailing: the wait while active, `live.go` when called, the stage when serving.
    public static func compactTrailing(_ state: TicketLiveState, lang: Lang) -> String {
        switch LiveTicketRules.phase(state) {
        case .active: wait(state, lang: lang)
        case .called: t(lang, "live.go")
        case .serving: stageName(state, lang: lang) ?? "–"
        case .between, .ended: "–"
        }
    }

    /// What VoiceOver reads for the whole activity, with no isolates.
    public static func spoken(_ state: TicketLiveState, lang: Lang, isStale: Bool) -> String {
        var parts: [String] = []
        if !state.centreName.isEmpty { parts.append(state.centreName) }
        switch LiveTicketRules.phase(state) {
        case .ended:
            parts.append(t(lang, "complete.title"))
        case .between:
            parts.append(t(lang, "ticket.nextStep"))
            if let stage = stageName(state, lang: lang) { parts.append(stage) }
        case .active, .called, .serving:
            if let number = state.number { parts.append("\(t(lang, "ticket.numberLabel")) \(number)") }
            if let stage = stageName(state, lang: lang) { parts.append(stage) }
            switch LiveTicketRules.phase(state) {
            case .called: parts.append(goNow(state, lang: lang))
            case .serving: parts.append(t(lang, "ticket.withTeam"))
            default:
                parts.append("\(t(lang, "ticket.peopleAhead")) \(peopleAhead(state))")
                parts.append("\(t(lang, "ticket.estimatedWait")) \(wait(state, lang: lang))")
            }
        }
        if isStale { parts.append(t(lang, "ticket.slower")) }
        return strip(parts.joined(separator: ", "))
    }
}

// MARK: Shared pieces

extension Lang {
    /// The same locale the app's root sets: Latin digits and the Gregorian calendar.
    fileprivate var liveLocale: Locale {
        Locale(identifier: self == .ar ? "ar_QA@numbers=latn;calendar=gregorian" : "en_GB")
    }

    /// `.caption`, which Arabic steps up to `.footnote`, as the app's text roles do.
    fileprivate var caption: Font { self == .ar ? .footnote : .caption }
}

private struct LiveEnvironment: ViewModifier {
    let lang: Lang

    func body(content: Content) -> some View {
        content
            .lineLimit(1)
            .dynamicTypeSize(...DynamicTypeSize.xLarge)
            .environment(\.layoutDirection, lang.dir == .rtl ? .rightToLeft : .leftToRight)
            .environment(\.locale, lang.liveLocale)
    }
}

extension View {
    fileprivate func live(_ lang: Lang) -> some View {
        modifier(LiveEnvironment(lang: lang))
    }
}

/// `StageTrack(.compact)` for the Live views: triage, doctor, pharmacy, which differ by shape as
/// well as colour, and follow the reading direction. Only the current stop is in the hue.
public struct TicketLiveStageTrack: View {
    let stage: VisitStage
    let lang: Lang
    let colors: TicketLiveColors

    public init(stage: VisitStage, lang: Lang, colors: TicketLiveColors) {
        self.stage = stage
        self.lang = lang
        self.colors = colors
    }

    private enum Mark { case done, current, future }
    private static let keys = ["ticket.stepTriage", "ticket.stepDoctor", "ticket.stepPharmacy"]
    private static let slot: CGFloat = 16
    private static let dot: CGFloat = 8

    private var current: Int? {
        switch stage {
        case .triage: 0
        case .doctor: 1
        case .pharmacy: 2
        case .completed: Self.keys.count
        default: nil
        }
    }

    private func mark(_ index: Int) -> Mark {
        guard let current else { return .future }
        if index < current { return .done }
        return index == current ? .current : .future
    }

    public var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.keys.indices, id: \.self) { index in
                VStack(spacing: 2) {
                    ZStack {
                        HStack(spacing: 0) {
                            connector(index == 0 ? nil : index - 1)
                            Color.clear.frame(width: Self.slot, height: 2)
                            connector(index == Self.keys.count - 1 ? nil : index)
                        }
                        marker(mark(index))
                    }
                    .frame(height: 10)
                    Text(verbatim: TicketLiveText.t(lang, Self.keys[index]))
                        .font(lang.caption)
                        .foregroundStyle(labelColor(mark(index)))
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func connector(_ from: Int?) -> some View {
        if let from {
            (mark(from) == .done ? colors.ink : colors.control).frame(height: 2)
        } else {
            Color.clear.frame(height: 2)
        }
    }

    @ViewBuilder
    private func marker(_ mark: Mark) -> some View {
        switch mark {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(colors.ink)
        case .current:
            Circle().fill(colors.hue).frame(width: Self.dot, height: Self.dot)
        case .future:
            Circle().strokeBorder(colors.control, lineWidth: 2).frame(width: Self.dot, height: Self.dot)
        }
    }

    private func labelColor(_ mark: Mark) -> Color {
        switch mark {
        case .current: colors.hue
        case .done: colors.ink
        case .future: colors.muted
        }
    }
}

/// The number at `font`, in the hue, changing as a counter does.
private struct LiveNumber: View {
    let state: TicketLiveState
    let font: Font
    let color: Color
    var scale: CGFloat = 0.7

    var body: some View {
        Text(verbatim: TicketLiveText.number(state) ?? "")
            .font(font.monospacedDigit())
            .foregroundStyle(color)
            .minimumScaleFactor(scale)
            .contentTransition(.numericText())
    }
}

private struct Completed: View {
    let lang: Lang
    let font: Font
    let colors: TicketLiveColors

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(font.weight(.semibold))
                .foregroundStyle(colors.ink)
            Text(verbatim: TicketLiveText.t(lang, "complete.title"))
                .font(font.weight(.semibold))
                .foregroundStyle(colors.ink)
                .minimumScaleFactor(0.7)
        }
    }
}

// MARK: Lock Screen

/// The Lock Screen and the banner, at most 160 pt. Row 1 the centre, or `ticket.slower` when
/// stale. Row 2 the number and the two figures. Row 3 the compact track. Row 4 the footer.
public struct TicketLiveLockScreen: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    private var colors: TicketLiveColors { .lockScreen(scheme, contrast: contrast) }
    private var phase: LiveTicketPhase { LiveTicketRules.phase(state) }
    /// The figures go grey when the system says the activity is out of date.
    private var figureColor: Color { isStale ? colors.muted : colors.ink }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Above `.large`, Row 1 goes, so the whole stays under 160 pt.
            if typeSize <= .large {
                Text(verbatim: isStale ? TicketLiveText.t(lang, "ticket.slower") : TicketLiveText.auto(state.centreName))
                    .font(lang.caption)
                    .foregroundStyle(colors.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .center, spacing: 12) {
                lead
                Spacer(minLength: 0)
                figures
            }
            TicketLiveStageTrack(stage: state.stage, lang: lang, colors: colors)
            Text(verbatim: TicketLiveText.t(lang, "footer.demo"))
                .font(.caption2)
                .foregroundStyle(colors.muted)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .live(lang)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketLiveText.spoken(state, lang: lang, isStale: isStale)))
    }

    @ViewBuilder
    private var lead: some View {
        switch phase {
        case .ended:
            Completed(lang: lang, font: .title2, colors: colors)
        case .between:
            Text(verbatim: TicketLiveText.t(lang, "ticket.nextStep"))
                .font(.title3.weight(.semibold))
                .foregroundStyle(colors.ink)
                .minimumScaleFactor(0.6)
        case .active, .called, .serving:
            LiveNumber(
                state: state, font: .system(size: 44, weight: .semibold), color: colors.hue, scale: 0.5)
                .layoutPriority(1)
        }
    }

    @ViewBuilder
    private var figures: some View {
        switch phase {
        case .active:
            HStack(alignment: .top, spacing: 16) {
                stat(TicketLiveText.peopleAhead(state), label: "ticket.peopleAhead")
                stat(TicketLiveText.wait(state, lang: lang), label: "ticket.estimatedWait")
            }
        case .called:
            Text(verbatim: TicketLiveText.goNow(state, lang: lang))
                .font(.headline.weight(.semibold))
                .foregroundStyle(figureColor)
                .minimumScaleFactor(0.7)
        case .serving:
            Text(verbatim: TicketLiveText.t(lang, "ticket.withTeam"))
                .font(.headline.weight(.semibold))
                .foregroundStyle(figureColor)
                .minimumScaleFactor(0.7)
        case .between, .ended:
            EmptyView()
        }
    }

    private func stat(_ value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(verbatim: value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(figureColor)
                .contentTransition(.numericText())
            Text(verbatim: TicketLiveText.t(lang, label))
                .font(lang.caption)
                .foregroundStyle(colors.muted)
                .minimumScaleFactor(0.8)
        }
    }
}

// MARK: Dynamic Island

/// Compact leading: the number in the hue, or a clock when there is none.
public struct TicketLiveCompactLeading: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        Group {
            switch LiveTicketRules.phase(state) {
            case .ended:
                Image(systemName: "checkmark").foregroundStyle(colors.ink)
            case .between:
                Image(systemName: "clock").foregroundStyle(colors.ink)
            case .active, .called, .serving:
                LiveNumber(state: state, font: .caption.weight(.semibold), color: colors.hue)
            }
        }
        .font(.caption.weight(.semibold))
        .live(lang)
        .accessibilityLabel(Text(verbatim: TicketLiveText.spoken(state, lang: lang, isStale: isStale)))
    }
}

/// Compact trailing: `12 min` while active, `live.go` when called, the stage when serving.
public struct TicketLiveCompactTrailing: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        Text(verbatim: TicketLiveText.compactTrailing(state, lang: lang))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(isStale ? colors.muted : colors.ink)
            .minimumScaleFactor(0.7)
            .contentTransition(.numericText())
            .live(lang)
            .accessibilityHidden(true)
    }
}

/// Minimal: the last three digits in the hue, or a clock when there is no number.
public struct TicketLiveMinimal: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        Group {
            switch LiveTicketRules.phase(state) {
            case .ended:
                Image(systemName: "checkmark").foregroundStyle(colors.ink)
            case .between:
                Image(systemName: "clock").foregroundStyle(colors.ink)
            case .active, .called, .serving:
                Text(verbatim: TicketLiveText.minimalNumber(state) ?? "")
                    .foregroundStyle(colors.hue)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
            }
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .live(lang)
        .accessibilityLabel(Text(verbatim: TicketLiveText.spoken(state, lang: lang, isStale: isStale)))
    }
}

/// Expanded leading: the number at `.title2`, then the stage name, both in the hue.
public struct TicketLiveExpandedLeading: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        VStack(alignment: .leading, spacing: 2) {
            switch LiveTicketRules.phase(state) {
            case .ended:
                Completed(lang: lang, font: .subheadline, colors: colors)
            case .between:
                Text(verbatim: TicketLiveText.t(lang, "ticket.nextStep"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(colors.ink)
                    .minimumScaleFactor(0.6)
            case .active, .called, .serving:
                LiveNumber(state: state, font: .title2.weight(.semibold), color: colors.hue)
            }
            if LiveTicketRules.phase(state) != .ended, let stage = TicketLiveText.stageName(state, lang: lang) {
                Text(verbatim: stage)
                    .font(lang.caption)
                    .foregroundStyle(colors.hue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .live(lang)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: TicketLiveText.spoken(state, lang: lang, isStale: isStale)))
    }
}

/// Expanded trailing: the wait, then how many are ahead. `live.go` when called.
public struct TicketLiveExpandedTrailing: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        let figure = isStale ? colors.muted : colors.ink
        VStack(alignment: .trailing, spacing: 2) {
            switch LiveTicketRules.phase(state) {
            case .active:
                Text(verbatim: TicketLiveText.wait(state, lang: lang))
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(figure)
                    .contentTransition(.numericText())
                Text(verbatim: TicketLiveText.ahead(state, lang: lang))
                    .font(lang.caption)
                    .foregroundStyle(colors.muted)
            case .called:
                Text(verbatim: TicketLiveText.t(lang, "live.go"))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(figure)
            case .serving:
                Text(verbatim: TicketLiveText.t(lang, "ticket.withTeam"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(figure)
            case .between, .ended:
                EmptyView()
            }
        }
        .minimumScaleFactor(0.6)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .live(lang)
        .accessibilityHidden(true)
    }
}

/// Expanded center: the centre's name, or `ticket.slower` when stale.
public struct TicketLiveExpandedCenter: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        Text(verbatim: isStale ? TicketLiveText.t(lang, "ticket.slower") : TicketLiveText.auto(state.centreName))
            .font(lang.caption)
            .foregroundStyle(colors.muted)
            .minimumScaleFactor(0.8)
            .live(lang)
            .accessibilityHidden(true)
    }
}

/// Expanded bottom: where to go when called, the compact track, then the footer.
public struct TicketLiveExpandedBottom: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: TicketLiveState, lang: Lang, isStale: Bool = false) {
        self.state = state
        self.lang = lang
        self.isStale = isStale
    }

    public var body: some View {
        let colors = TicketLiveColors.island(increasedContrast: contrast == .increased)
        VStack(alignment: .leading, spacing: 6) {
            if LiveTicketRules.phase(state) == .called {
                Text(verbatim: TicketLiveText.goNow(state, lang: lang))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(isStale ? colors.muted : colors.ink)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            TicketLiveStageTrack(stage: state.stage, lang: lang, colors: colors)
            Text(verbatim: TicketLiveText.t(lang, "footer.demo"))
                .font(.caption2)
                .foregroundStyle(colors.muted)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .live(lang)
        .accessibilityHidden(true)
    }
}
