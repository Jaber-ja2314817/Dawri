#if DEBUG
import DawriCore
import Foundation
import SwiftUI

/// The DEBUG launch hooks of S08 to S11, so a screenshot or a UI test reaches each state with no
/// tapping. Read through `DemoLaunch.current?.argument`, and all of it compiles out of Release
/// with the rest of `Debug/`.
///
///     -demoLocation near|far|fail|imprecise, what the phone's position answers. `near` is about
///       20 m from the visit's centre and `far` about 5.6 km. `imprecise` is approximate location
///       with the precise prompt declined. Without it, the phone's own `CoreLocationSource` reads
///       the simulator's or the phone's position
///     -demoMapFailed 1, S08's map reports that it failed through its `onFail`
///     -demoOffline 1, S08's network path probe reports no path, so S08 opens on the list only
///       with `centre.mapFailed`, as it would with no network
///     -demoView map|list, S08 starts on that view
///     -demoSelect <centreId>, S08 selects that centre on arrival, as a pin or row tap would
///     -demoLocate 1, S08 taps Use my location
///     -demoReserve 1, S08 taps Check in here
///     -demoSheet door, S09 opens the door code sheet
///     -demoDoorCode <text>, typed into that sheet
///     -demoCamera denied|unavailable|scan:<payload>, the door sheet's camera. `scan` reports that
///       payload once, a second after the preview shows, as the camera would read it
///     -demoArrive button|location|code, S09 taps I'm here, Check with my location, or the
///       sheet's Check in
///     -demoStep 1, S10 taps Demo: next step
///     -demoRate <1...5>, S11 taps that star
///     -demoScrollEnd 1, S11 scrolls to its last line
@MainActor
enum DemoVisit {
    private static var used: Set<String> = []

    private static func argument(_ name: String) -> String? {
        DemoLaunch.current?.argument(name)
    }

    /// True the first time only, so a hook that acts on appear does not act again.
    static func once(_ hook: String) -> Bool {
        used.insert(hook).inserted
    }

    /// The position source `-demoLocation` asks for, or the app's own.
    static func location(
        _ fallback: any LocationSource, service: any ClinicService, visitId: String
    ) -> any LocationSource {
        guard let kind = argument("demoLocation").flatMap(DemoLocation.Kind.init(rawValue:))
        else { return fallback }
        return DemoLocation(kind: kind, service: service, visitId: visitId)
    }

    // S08

    static var mapFails: Bool { argument("demoMapFailed") == "1" }
    static var view: String? { argument("demoView") }
    static var selection: String? { argument("demoSelect") }

    /// The probe `-demoOffline 1` asks for, which finds no path, or the app's own.
    static func pathProbe(_ fallback: any NetworkPathProbe) -> any NetworkPathProbe {
        argument("demoOffline") == "1" ? NoPathProbe() : fallback
    }
    static var locates: Bool { argument("demoLocate") == "1" }
    static var reserves: Bool { argument("demoReserve") == "1" }

    // S09

    static var opensDoorSheet: Bool { argument("demoSheet") == "door" }

    /// The camera `-demoCamera` asks for, or the app's own.
    static func scanner(_ fallback: any DoorScanner) -> any DoorScanner {
        guard let wanted = argument("demoCamera") else { return fallback }
        if wanted.hasPrefix("scan:") {
            return DemoDoorScanner(answer: .available, payload: String(wanted.dropFirst("scan:".count)))
        }
        switch wanted {
        case "denied": return DemoDoorScanner(answer: .denied, payload: nil)
        case "unavailable": return DemoDoorScanner(answer: .unavailable, payload: nil)
        default: return fallback
        }
    }
    static var doorCode: String? { argument("demoDoorCode") }
    static var arrival: String? { argument("demoArrive") }

    // S11

    static var rating: Int? { argument("demoRate").flatMap(Int.init) }
    static var steps: Bool { argument("demoStep") == "1" }
    static var scrollsToEnd: Bool { argument("demoScrollEnd") == "1" }
}

/// A phone with no network, as `NWPathMonitor` would report it in flight mode.
private struct NoPathProbe: NetworkPathProbe {
    func hasPath() async -> Bool { false }
}

/// A camera that answers as `-demoCamera` says, and reads one scripted payload.
private struct DemoDoorScanner: DoorScanner {
    let answer: CameraAccess
    let payload: String?

    func access() async -> CameraAccess { answer }
    func requestAccess() async -> CameraAccess { answer }

    @MainActor func preview(onRead: @escaping @MainActor (String) -> Bool) -> AnyView {
        AnyView(DemoScannerPreview(payload: payload, onRead: onRead))
    }
}

/// A still stand-in for the camera, which reports its payload once after a second.
private struct DemoScannerPreview: View {
    let payload: String?
    let onRead: @MainActor (String) -> Bool

    var body: some View {
        Rectangle()
            .fill(Color.black)
            .overlay {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(Color.white.opacity(0.7))
            }
            .task {
                guard let payload else { return }
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                _ = onRead(payload)
            }
    }
}

/// A position near or far from the visit's centre, read from the clinic itself, so it stays right
/// whichever centre the visit has. With no centre yet, the clinic's default centre stands in.
private struct DemoLocation: LocationSource {
    enum Kind: String {
        case near, far, fail, imprecise
    }

    let kind: Kind
    let service: any ClinicService
    let visitId: String

    func currentPoint() async throws -> LocationPoint {
        if kind == .fail { throw PhoneFeatureError.unavailable }
        if kind == .imprecise { throw LocationFailure.imprecise }
        let visit = try await service.getVisit(visitId: visitId)
        let list = try await service.listCentres(
            service: (visit.service ?? .gp).rawValue, visitId: visitId, lat: nil, lng: nil)
        let wanted = visit.ticket?.centreId ?? visit.centre?.id ?? list.defaultCentreId
        guard let centre = list.centres.first(where: { $0.id == wanted }) ?? list.centres.first
        else { throw PhoneFeatureError.unavailable }
        // 0.0002 degrees of latitude is about 22 m, and 0.05 about 5.6 km.
        let offset = kind == .near ? 0.0002 : 0.05
        return LocationPoint(lat: centre.lat + offset, lng: centre.lng)
    }
}
#endif
