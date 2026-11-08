import DawriCore
import MapKit
import Network
import os
import SwiftUI

/// S08's map. The port of frontend/src/features/map/CentreMap.tsx, on MapKit with no API key:
/// one `WaitBadge` per centre, the camera fitted once to every centre, and a tap that changes the
/// selection and nothing else.
///
/// - The map is forced left to right, as the web's `dir="ltr"` holder is, so east stays right and
///   MapKit's legal link and controls stay put in Arabic. Each badge takes the app's direction back,
///   so `12 د` still reads in Arabic order.
/// - The camera fits all centres with 48 pt of padding and comes no closer than the web's zoom 13,
///   with no animation. It is set again only when the set of centres changes, never on a tap.
/// - The selected badge is ink, never the hue, and MapKit's selection lifts it above the others.
///
/// A failed map is reported through `onFail`, which S08 shows as `centre.mapFailed` with the list
/// only. S08 itself asks `NetworkPathProbe` at entry, because MapKit gives no failure callback, and
/// a DEBUG launch with `-demoMapFailed 1` reports one from here.
struct CentreMap: View {
    let centres: [CentreOption]
    let selectedId: String?
    let onSelect: (String) -> Void
    let onFail: () -> Void

    @Environment(\.lang) private var lang
    @State private var position: MapCameraPosition = .automatic
    @State private var size: CGSize = .zero
    /// The centres the camera was last fitted to.
    @State private var fittedTo: [String] = []

    static let minHeight: CGFloat = 220
    static let share: CGFloat = 0.44

    var body: some View {
        Map(
            position: $position, interactionModes: [.pan, .zoom], selection: mapSelection
        ) {
            ForEach(centres, id: \.id) { centre in
                // MapKit exposes a point element of its own for every annotation, named by this
                // title, or "Map pin" in the phone's language without one. So the title is the
                // centre's name in the app's language, and the visible title stays hidden.
                Annotation(
                    centreName(centre, lang: lang),
                    coordinate: CLLocationCoordinate2D(latitude: centre.lat, longitude: centre.lng),
                    anchor: .center
                ) {
                    pin(centre)
                }
                .tag(centre.id)
            }
            .annotationTitles(.hidden)
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .mapControls {}
        .environment(\.layoutDirection, .leftToRight)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            fit()
        }
        .onChange(of: centres.map(\.id)) { fit() }
        .frame(maxWidth: .infinity)
        .modifier(CentreMapFrame())
        .overlay(alignment: .top) { DS.Color.hairline.frame(height: DS.Stroke.edge) }
        .overlay(alignment: .bottom) { DS.Color.hairline.frame(height: DS.Stroke.edge) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: lang.t("centre.mapLabel")))
        .accessibilityIdentifier("centre-map")
        #if DEBUG
        .task {
            if DemoVisit.mapFails { onFail() }
        }
        #endif
    }

    /// MapKit's own selection, read only, so the selected annotation sits on top. Changing it is
    /// the pin's button, so a tap and a list tap take the same path.
    private var mapSelection: Binding<String?> {
        Binding(get: { selectedId }, set: { _ in })
    }

    private func pin(_ centre: CentreOption) -> some View {
        let chosen = centre.id == selectedId
        return Button {
            onSelect(centre.id)
        } label: {
            WaitBadge(minutes: centre.waitMin, selected: chosen)
        }
        .buttonStyle(PinButtonStyle())
        .environment(\.layoutDirection, lang.layoutDirection)
        .accessibilityLabel(Text(verbatim: pinLabel(centre)))
        // The trait is spoken in the phone's language, so the value says it in the app's.
        .accessibilityValue(Text(verbatim: chosen ? lang.t("centre.pinSelected") : ""))
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("centre-pin-\(centre.id)")
    }

    /// The web's `centre.pinLabel`, with the web's `-` for a wait nobody knows.
    private func pinLabel(_ centre: CentreOption) -> String {
        lang.t("centre.pinLabel", [
            "name": centreName(centre, lang: lang),
            "wait": centre.waitMin.map(String.init) ?? "-",
            "unit": lang.t("centre.unitMin"),
        ])
    }

    /// Fits the camera to the centres once per set, after the map has a size, with no animation.
    private func fit() {
        let ids = centres.map(\.id)
        guard size.width > 0, size.height > 0, !centres.isEmpty, ids != fittedTo else { return }
        fittedTo = ids
        let points = centres.map { CLLocationCoordinate2D(latitude: $0.lat, longitude: $0.lng) }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            position = .rect(CentreMapFit.rect(fitting: points, in: size))
        }
    }
}

/// Leaflet's `fitBounds(bounds, { padding: [48, 48], maxZoom: 13 })`, in MapKit's terms.
enum CentreMapFit {
    static let padding: CGFloat = 48
    /// Map points per screen point at the web's closest fit. Leaflet's zoom 13 draws the world
    /// 256 × 2¹³ points wide, and MapKit's world is 2²⁸ map points wide, so one point is
    /// 2²⁸ / 2²¹ = 128 map points.
    static let closestScale = MKMapSize.world.width / (256 * pow(2, 13))

    /// The visible rect that holds every point inside the padding, centred on them, at the scale
    /// of the more crowded axis and never closer than zoom 13.
    static func rect(fitting points: [CLLocationCoordinate2D], in size: CGSize) -> MKMapRect {
        let mapPoints = points.map(MKMapPoint.init)
        let xs = mapPoints.map(\.x)
        let ys = mapPoints.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 0
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 0
        let inner = CGSize(
            width: max(size.width - 2 * padding, 1), height: max(size.height - 2 * padding, 1))
        let scale = max((maxX - minX) / inner.width, (maxY - minY) / inner.height, closestScale)
        let width = size.width * scale
        let height = size.height * scale
        return MKMapRect(
            x: (minX + maxX) / 2 - width / 2, y: (minY + maxY) / 2 - height / 2,
            width: width, height: height)
    }
}

/// A pin presses like every other target, at touch-down, with no scale under Reduce Motion. The
/// badge's own fill is the selection.
private struct PinButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(
                DS.Motion.resolved(
                    configuration.isPressed ? DS.Motion.press : DS.Motion.release,
                    reduceMotion: reduceMotion),
                value: configuration.isPressed)
    }
}

/// The map's height: a share of the viewport with a floor, edge to edge with square corners.
/// Shared with S08's loading bar, so the bar is the size of what lands.
struct CentreMapFrame: ViewModifier {
    func body(content: Content) -> some View {
        content.containerRelativeFrame(.vertical) { length, _ in
            max(CentreMap.minHeight, length * CentreMap.share)
        }
    }
}

/// Whether the phone has any network path, asked once as S08 opens. MapKit says nothing when its
/// tiles cannot load, so no path at entry is how S08 knows the map would be an empty grid.
protocol NetworkPathProbe: Sendable {
    func hasPath() async -> Bool
}

/// `NWPathMonitor`'s first answer. Only `unsatisfied` is no path: a path that needs a connection
/// first can still bring the tiles.
struct SystemPathProbe: NetworkPathProbe {
    func hasPath() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let answered = OSAllocatedUnfairLock(initialState: false)
            monitor.pathUpdateHandler = { path in
                let first = answered.withLock { done in
                    defer { done = true }
                    return !done
                }
                guard first else { return }
                monitor.cancel()
                continuation.resume(returning: path.status != .unsatisfied)
            }
            monitor.start(queue: DispatchQueue(label: "dawri.centre.path"))
        }
    }
}
