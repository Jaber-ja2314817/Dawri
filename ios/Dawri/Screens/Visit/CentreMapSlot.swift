import DawriCore
import SwiftUI

/// S08's map, and the one view the map phase replaces with MapKit. Until then it is an honest
/// flat ground that says so and draws no pins, because a pin here would be a fake map.
///
/// The geometry is the map's own, so nothing moves when MapKit arrives: edge to edge, 44% of
/// the viewport's height and never under 220 pt, with square corners. The real map reports a
/// failure through `onFail`, which S08 shows as `centre.mapFailed` with the list only. A DEBUG
/// launch with `-demoMapFailed 1` reports one here.
struct CentreMapSlot: View {
    let centres: [CentreOption]
    let selectedId: String?
    let onSelect: (String) -> Void
    let onFail: () -> Void

    @Environment(\.lang) private var lang

    static let minHeight: CGFloat = 220
    static let share: CGFloat = 0.44

    var body: some View {
        VStack(spacing: DS.Space.s) {
            Image(systemName: "map")
                .dsText(.screenTitle)
                .foregroundStyle(DS.Color.muted)
                .accessibilityHidden(true)
            Text(verbatim: lang.t("centre.mapPlaceholder"))
                .dsText(.secondary)
                .foregroundStyle(DS.Color.muted)
                .multilineTextAlignment(.center)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .modifier(MapSlotFrame())
        .background(DS.Color.raised)
        .overlay(alignment: .top) { DS.Color.hairline.frame(height: DS.Stroke.edge) }
        .overlay(alignment: .bottom) { DS.Color.hairline.frame(height: DS.Stroke.edge) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(verbatim: "\(lang.t("centre.mapLabel")), \(lang.t("centre.mapPlaceholder"))"))
        .accessibilityIdentifier("centre-map")
        #if DEBUG
        .task {
            if DemoVisit.mapFails { onFail() }
        }
        #endif
    }
}

/// The map's height: a share of the viewport with a floor. Shared with S08's loading bar, so the
/// bar is the size of what lands.
struct MapSlotFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.containerRelativeFrame(.vertical) { length, _ in
            max(CentreMapSlot.minHeight, length * CentreMapSlot.share)
        }
    }
}
