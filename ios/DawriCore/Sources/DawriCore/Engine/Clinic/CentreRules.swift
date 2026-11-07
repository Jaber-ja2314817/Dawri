/// Port of backend/centres.py and the list route in backend/routers/centres.py. No model is
/// involved: a suggestion is a rule over the wait numbers, its reason is a fixed template, and
/// it never changes the patient's default centre.
public enum CentreRules {
    private static let emergencyService = "emergency"
    private static var constants: ClinicData.Constants { ClinicData.bundled.constants }

    /// The service a centre has to offer. Some are seen by a GP first.
    public static func routedService(_ service: String) -> String {
        constants.gpRouted.contains(service) ? "gp" : service
    }

    private static func km(_ origin: GeoPoint, lat: Double, lng: Double) -> Double {
        ClinicGeo.distanceM(origin.lat, origin.lng, lat, lng) / 1000
    }

    private static func km(_ origin: GeoPoint, _ centre: CentreRecord) -> Double {
        km(origin, lat: centre.lat, lng: centre.lng)
    }

    private static func km(_ origin: GeoPoint, _ option: CentreOption) -> Double {
        km(origin, lat: option.lat, lng: option.lng)
    }

    public static func registeredCentre(_ state: ClinicState, patientId: String) -> CentreRecord? {
        state.patient(patientId).flatMap { state.centre($0.registeredCentreId) }
    }

    private static func sortedById(_ rows: [CentreRecord]) -> [CentreRecord] {
        rows.sorted { $0.id < $1.id }
    }

    private static func hospitals(_ state: ClinicState) -> [CentreRecord] {
        sortedById(state.centres.filter { $0.hasEmergency == 1 })
    }

    public static func nearestEmergency(_ state: ClinicState, lat: Double, lng: Double) -> NearestEd? {
        let origin = GeoPoint(lat: lat, lng: lng)
        var best: (hospital: CentreRecord, km: Double)?
        for hospital in hospitals(state) {
            let distance = km(origin, hospital)
            if best == nil || distance < (best?.km ?? .infinity) { best = (hospital, distance) }
        }
        return best.map { found in
            NearestEd(
                id: found.hospital.id, nameEn: found.hospital.nameEn,
                nameAr: found.hospital.nameAr, lat: found.hospital.lat, lng: found.hospital.lng,
                distanceKm: ClinicText.roundedToTenth(found.km))
        }
    }

    /// Measured from the registered centre, because the chat has no location.
    public static func nearestEd(_ state: ClinicState, patientId: String) -> NearestEd? {
        registeredCentre(state, patientId: patientId).flatMap {
            nearestEmergency(state, lat: $0.lat, lng: $0.lng)
        }
    }

    /// Emergency departments by distance. They take no ticket, so they show no wait.
    public static func emergencyList(_ state: ClinicState, origin: GeoPoint?) -> [CentreOption] {
        let entries = hospitals(state).map { row in
            option(
                row, waitMin: nil, peopleAhead: nil,
                distanceKm: origin.map { ClinicText.roundedToTenth(km($0, row)) },
                registered: false)
        }
        guard let origin else { return entries }
        return entries.enumerated().sorted { first, second in
            let (kmFirst, kmSecond) = (km(origin, first.element), km(origin, second.element))
            return kmFirst != kmSecond ? kmFirst < kmSecond : first.offset < second.offset
        }.map(\.element)
    }

    private static func option(
        _ row: CentreRecord, waitMin: Int?, peopleAhead: Int?, distanceKm: Double?, registered: Bool
    ) -> CentreOption {
        CentreOption(
            id: row.id, nameEn: row.nameEn, nameAr: row.nameAr, operator: row.operator,
            lat: row.lat, lng: row.lng, waitMin: waitMin, peopleAhead: peopleAhead,
            distanceKm: distanceKm, registered: registered)
    }

    /// PHCC centres with this service. Hospitals are for emergencies only.
    public static func offering(_ state: ClinicState, service: String) -> [CentreRecord] {
        sortedById(state.centres.filter { $0.operator == "PHCC" && $0.services.contains(service) })
    }

    public static func entry(
        _ row: CentreRecord, wait: QueueWait, locatedAt: GeoPoint?, registeredId: String?
    ) -> CentreOption {
        option(
            row, waitMin: wait.waitMin, peopleAhead: wait.peopleAhead,
            distanceKm: locatedAt.map { ClinicText.roundedToTenth(km($0, row)) },
            registered: row.id == registeredId)
    }

    /// Registered centre first, then nearest if we have a location, else shortest wait.
    public static func rank(_ entries: [CentreOption], locatedAt: GeoPoint?) -> [CentreOption] {
        func measure(_ item: CentreOption) -> Double {
            if let locatedAt { return km(locatedAt, item) }
            return Double(item.waitMin ?? 0)
        }
        return entries.enumerated().sorted { first, second in
            let (a, b) = (first.element, second.element)
            if a.registered != b.registered { return a.registered }
            let (measureA, measureB) = (measure(a), measure(b))
            if measureA != measureB { return measureA < measureB }
            if a.id != b.id { return a.id < b.id }
            return first.offset < second.offset
        }.map(\.element)
    }

    /// Another centre that is near and much shorter, or nil.
    public static func suggest(_ entries: [CentreOption], reference: GeoPoint?) -> CentreSuggestion? {
        guard let registered = entries.first(where: \.registered), let reference,
              let usual = registered.waitMin
        else { return nil }
        let longestWait = usual - constants.muchShorterMin
        let candidates = entries.filter { item in
            guard !item.registered, let wait = item.waitMin else { return false }
            return km(reference, item) <= Double(constants.nearKm) && wait <= longestWait
        }
        let best = candidates.enumerated().min { first, second in
            let (a, b) = (first.element, second.element)
            if a.waitMin != b.waitMin { return (a.waitMin ?? 0) < (b.waitMin ?? 0) }
            let (kmA, kmB) = (km(reference, a), km(reference, b))
            if kmA != kmB { return kmA < kmB }
            if a.id != b.id { return a.id < b.id }
            return first.offset < second.offset
        }?.element
        guard let best, let wait = best.waitMin else { return nil }
        let templates = ClinicData.bundled.text.templates.suggestionReason
        func reason(_ template: String, name: String) -> String {
            ClinicText.fill(template, ["name": name, "wait": String(wait), "usual": String(usual)])
        }
        return CentreSuggestion(
            centreId: best.id, reasonEn: reason(templates.en, name: best.nameEn),
            reasonAr: reason(templates.ar, name: best.nameAr))
    }

    /// `list_centres`, for the patient the visit belongs to. A registered centre without this
    /// service is no default: reserving there is refused.
    public static func list(
        _ state: ClinicState, engine: QueueEngine, patientId: String, service: String,
        lat: Double? = nil, lng: Double? = nil
    ) throws -> CentreList {
        guard service == emergencyService || Service(rawValue: service) != nil else {
            throw ClinicError(
                status: 422, code: "unknown_service", message: "We do not know this service.")
        }
        let home = registeredCentre(state, patientId: patientId)
        let homePoint = home.map { GeoPoint(lat: $0.lat, lng: $0.lng) }
        var locatedAt: GeoPoint?
        if let lat, let lng { locatedAt = GeoPoint(lat: lat, lng: lng) }
        let reference = locatedAt ?? homePoint

        let effective: String
        let listed: [CentreOption]
        var suggestion: CentreSuggestion?
        if service == emergencyService {
            effective = emergencyService
            listed = emergencyList(state, origin: reference)
        } else {
            effective = routedService(service)
            let entries = offering(state, service: effective).map { row in
                entry(
                    row, wait: engine.centreWait(state, centreId: row.id, service: effective),
                    locatedAt: locatedAt, registeredId: home?.id)
            }
            listed = rank(entries, locatedAt: locatedAt)
            suggestion = suggest(listed, reference: reference)
        }
        return CentreList(
            service: service, effectiveService: effective, serviceFallback: effective != service,
            defaultCentreId: listed.first(where: \.registered)?.id, centres: listed,
            suggestion: suggestion)
    }
}
