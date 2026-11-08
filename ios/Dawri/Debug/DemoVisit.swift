#if DEBUG
import DawriCore
import Foundation

/// The DEBUG launch hooks of S08 to S11, so a screenshot or a UI test reaches each state with no
/// tapping. Read through `DemoLaunch.current?.argument`, and all of it compiles out of Release
/// with the rest of `Debug/`.
///
///     -demoLocation near|far|fail, what the phone's position answers. `near` is about 20 m from
///       the visit's centre and `far` about 5.6 km. In Release the source is `NoLocationSource`,
///       which always throws, so S08 and S09 show their location-failed states
///     -demoMapFailed 1, S08's map slot reports that it failed, as a map with no network would
///     -demoView map|list, S08 starts on that view
///     -demoLocate 1, S08 taps Use my location
///     -demoReserve 1, S08 taps Check in here
///     -demoSheet door, S09 opens the door code sheet
///     -demoDoorCode <text>, typed into that sheet
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
    static var locates: Bool { argument("demoLocate") == "1" }
    static var reserves: Bool { argument("demoReserve") == "1" }

    // S09

    static var opensDoorSheet: Bool { argument("demoSheet") == "door" }
    static var doorCode: String? { argument("demoDoorCode") }
    static var arrival: String? { argument("demoArrive") }

    // S11

    static var rating: Int? { argument("demoRate").flatMap(Int.init) }
    static var steps: Bool { argument("demoStep") == "1" }
    static var scrollsToEnd: Bool { argument("demoScrollEnd") == "1" }
}

/// A position near or far from the visit's centre, read from the clinic itself, so it stays right
/// whichever centre the visit has. With no centre yet, the clinic's default centre stands in.
private struct DemoLocation: LocationSource {
    enum Kind: String {
        case near, far, fail
    }

    let kind: Kind
    let service: any ClinicService
    let visitId: String

    func currentPoint() async throws -> LocationPoint {
        if kind == .fail { throw PhoneFeatureError.unavailable }
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
