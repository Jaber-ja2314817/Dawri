import DawriCore
import SwiftUI

/// The largest thing in the app, and the one centred moment. A reserved visit never uses it.
struct TicketNumberBlock: View {
    let number: String?
    let stage: VisitStage?

    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        VStack(spacing: DS.Space.l) {
            Group {
                if let number {
                    // Sized by width rather than the user's text size, so it cannot clip.
                    Text(verbatim: number)
                        .speechSpellsOutCharacters()
                        .font(DS.TextRole.ticketNumber.font(for: lang))
                        .foregroundStyle(DS.Color.hue)
                        .lineLimit(1)
                        .minimumScaleFactor(0.25)
                        .frame(maxWidth: .infinity)
                        .environment(\.layoutDirection, .leftToRight)
                        .id(number)
                        .transition(
                            reduceMotion
                                ? .opacity
                                : .opacity.combined(with: .offset(y: 6)))
                        .accessibilityLabel(Text(verbatim: lang.t("ticket.numberLabel")))
                        .accessibilityValue(Text(verbatim: number).speechSpellsOutCharacters())
                        .accessibilityAddTraits(.updatesFrequently)
                        .accessibilityIdentifier("ticket-number")
                } else {
                    Text(verbatim: lang.t("ticket.nextStep"))
                        .dsText(.section)
                        .foregroundStyle(DS.Color.ink)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(
                DS.Motion.resolved(DS.Motion.number, reduceMotion: reduceMotion), value: number)
            StageTrack(stage: stage)
        }
        .padding(.vertical, DS.Space.xl)
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity)
        .background(DS.Color.surface, in: shape)
        .overlay(shape.strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.edge))
    }
}

/// A clock jumps, so there is no animation. It reads left to right in both languages, holds at
/// `0:00`, and VoiceOver reads it as a value rather than every second.
struct CountdownText: View {
    let expiresAt: Date

    @Environment(\.lang) private var lang

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(expiresAt.timeIntervalSince(context.date).rounded(.up)))
            let clock = "\(left / 60):\(String(format: "%02d", left % 60))"
            Text(verbatim: clock)
                .dsText(.countdown)
                .foregroundStyle(DS.Color.ink)
                .contentTransition(.identity)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(Text(verbatim: lang.t("reserved.timeLeft")))
                .accessibilityValue(Text(verbatim: clock))
        }
    }
}

/// For map pins, through `Annotation` with `anchor: .center`.
struct WaitBadge: View {
    let minutes: Int?
    var selected = false

    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        Group {
            if minutes == nil {
                Text(verbatim: "–")
            } else {
                Measure(value: minutes, unit: lang.t("centre.unitMin"))
            }
        }
        .dsText(.badge)
        .foregroundStyle(selected ? DS.Color.primaryText : DS.Color.ink)
        .padding(.horizontal, DS.Space.s)
        .frame(height: 28)
        .background(selected ? DS.Color.primaryFill : DS.Color.surface, in: shape)
        .overlay {
            if !selected {
                shape.strokeBorder(DS.Color.control, lineWidth: DS.Stroke.edge)
            }
        }
        .frame(minWidth: DS.Size.minTarget, minHeight: DS.Size.minTarget)
        .contentShape(Rectangle())
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .accessibilityShowsLargeContentViewer()
        .animation(DS.Motion.resolved(DS.Motion.press, reduceMotion: reduceMotion), value: selected)
    }
}

/// Five 44 pt targets. Without `onRate` it is the read-only row shown once a rating is sent.
struct StarRating: View {
    let rating: Int?
    var onRate: ((Int) -> Void)?

    @Environment(\.lang) private var lang
    @State private var picked = 0

    var body: some View {
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { star in
                let filled = star <= (rating ?? 0)
                let label = lang.t("complete.stars", ["stars": star])
                if let onRate {
                    Button {
                        picked = star
                        onRate(star)
                    } label: {
                        symbol(filled)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(verbatim: label))
                    .accessibilityAddTraits(filled ? .isSelected : [])
                } else {
                    symbol(filled)
                        .accessibilityLabel(Text(verbatim: label))
                        .accessibilityHidden(star != rating)
                }
            }
        }
        .sensoryFeedback(DS.Haptic.select, trigger: picked)
    }

    private func symbol(_ filled: Bool) -> some View {
        Image(systemName: filled ? "star.fill" : "star")
            .font(.title3)
            .foregroundStyle(DS.Color.ink)
            .frame(width: DS.Size.minTarget, height: DS.Size.minTarget)
            .contentShape(Rectangle())
    }
}

/// S10 only, in On this phone mode. Always says Demo, and never looks like staff.
struct DemoNextStepButton: View {
    let action: () -> Void

    @Environment(\.lang) private var lang

    var body: some View {
        Button(lang.t("demo.nextStep"), action: action)
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("demo-next-step")
    }
}

/// Wraps chips onto as many lines as they need. SwiftUI mirrors a custom layout's placement in
/// right-to-left, so this works in leading-edge terms.
struct ChipFlow: Layout {
    var spacing: CGFloat = DS.Space.s

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = rows(for: subviews, width: width)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let used = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (row.height - size.height) / 2),
                    proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let next = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if next > width, !row.indices.isEmpty {
                rows.append(row)
                row = Row()
                row.width = size.width
            } else {
                row.width = next
            }
            row.indices.append(index)
            row.height = max(row.height, size.height)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
