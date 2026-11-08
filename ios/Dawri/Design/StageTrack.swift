import DawriCore
import SwiftUI

enum TrackStyle {
    case full, compact
}

/// Triage, doctor, pharmacy. The three states differ by shape and weight, so colour is never
/// alone, and the track follows reading direction.
struct StageTrack: View {
    let stage: VisitStage?
    var style: TrackStyle = .full

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Mark {
        case done, current, future
    }

    private static let keys = ["ticket.stepTriage", "ticket.stepDoctor", "ticket.stepPharmacy"]

    private var currentIndex: Int? {
        switch stage {
        case .triage: 0
        case .doctor: 1
        case .pharmacy: 2
        default: nil
        }
    }

    private func mark(_ index: Int) -> Mark {
        guard let currentIndex else { return .future }
        if index < currentIndex { return .done }
        return index == currentIndex ? .current : .future
    }

    /// The width a marker's slot takes on the line, so connectors stop short of the markers.
    private var slot: CGFloat { style == .full ? 26 : 16 }
    private var dot: CGFloat { style == .full ? DS.Size.stageDot : DS.Size.stageDotCompact }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize && style == .full {
                vertical
            } else {
                horizontal
            }
        }
        .animation(
            DS.Motion.resolved(DS.Motion.stage, reduceMotion: reduceMotion), value: stage)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: spoken))
        .accessibilityIdentifier("stage-track")
    }

    private var spoken: String {
        let steps = lang.t("ticket.stepsLabel")
        guard let currentIndex else { return steps }
        let step = lang.t("track.stepOf", ["step": currentIndex + 1, "total": Self.keys.count])
        return "\(steps), \(lang.t(Self.keys[currentIndex])), \(step)"
    }

    private var horizontal: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Self.keys.indices, id: \.self) { index in
                VStack(spacing: DS.Space.xs) {
                    ZStack {
                        HStack(spacing: 0) {
                            connector(before: index).frame(height: 2)
                            Color.clear.frame(width: slot, height: 2)
                            connector(after: index).frame(height: 2)
                        }
                        marker(mark(index))
                    }
                    .frame(height: style == .full ? 16 : 10)
                    label(index)
                        .multilineTextAlignment(.center)
                        .lineLimit(style == .compact ? 1 : nil)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }

    private var vertical: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Self.keys.indices, id: \.self) { index in
                HStack(alignment: .center, spacing: DS.Space.m) {
                    marker(mark(index)).frame(width: slot)
                    label(index)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if index < Self.keys.count - 1 {
                    connectorColor(index)
                        .frame(width: 2, height: DS.Space.m)
                        .padding(.vertical, DS.Space.xxs)
                        .frame(width: slot)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func connector(before index: Int) -> some View {
        if index == 0 { Color.clear } else { connectorColor(index - 1) }
    }

    @ViewBuilder
    private func connector(after index: Int) -> some View {
        if index == Self.keys.count - 1 { Color.clear } else { connectorColor(index) }
    }

    /// The connector from stop `index` to the next.
    private func connectorColor(_ index: Int) -> Color {
        mark(index) == .done ? DS.Color.ink : DS.Color.control
    }

    @ViewBuilder
    private func marker(_ mark: Mark) -> some View {
        switch mark {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: style == .full ? 14 : 9, weight: .semibold))
                .foregroundStyle(DS.Color.ink)
        case .current:
            Circle().fill(DS.Color.hue).frame(width: dot, height: dot)
        case .future:
            Circle().strokeBorder(DS.Color.control, lineWidth: 2).frame(width: dot, height: dot)
        }
    }

    private func label(_ index: Int) -> some View {
        let state = mark(index)
        return Text(verbatim: lang.t(Self.keys[index]))
            .dsText(style == .compact ? .caption : (state == .current ? .secondaryStrong : .secondary))
            .foregroundStyle(
                state == .current ? DS.Color.hue : (state == .done ? DS.Color.ink : DS.Color.muted))
    }
}
