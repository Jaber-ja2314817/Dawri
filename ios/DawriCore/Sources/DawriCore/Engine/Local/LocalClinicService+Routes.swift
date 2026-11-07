import Foundation

/// The patient routes of backend/routers/auth.py, visits.py and centres.py, with the same
/// refusals in the same order: the session, then the visit, then the body, then the route.
///
/// `ClinicService`'s types cannot spell a missing field or a second arrival method, but the
/// routes refuse those, so the checks live in `route...` methods that take what a request could
/// hold, and each public method is a thin call to one.
extension LocalClinicService {
    private var constants: ClinicData.Constants { ClinicData.bundled.constants }
    private var visitsText: ClinicData.Text.Visits { ClinicData.bundled.text.visits }

    private var today: AgeReference { .instant(clock()) }

    private static let invalidRequest = ClinicError(
        status: 422, code: "invalid_request",
        message: "The request body or parameters are not valid.")

    // deps.py

    /// `require_patient`.
    private func requirePatient() throws -> String {
        guard let subject = state.subject else {
            throw ClinicError(
                status: 401, code: "unauthorized", message: "A valid session token is required.")
        }
        guard subject.kind == .patient else {
            throw ClinicError(
                status: 403, code: "forbidden", message: "This route needs a patient session.")
        }
        return subject.id
    }

    /// `auth.can_access_patient`.
    private func canAccessPatient(subject: String, patientId: String) -> Bool {
        subject == patientId
            || state.clinic.dependentLinks.contains {
                $0.guardianId == subject && $0.dependentId == patientId
            }
    }

    /// `patient_may_see_visit`: the patient, their guardian, or whoever booked the visit.
    private func patientMaySee(subject: String, _ visit: VisitRecord) -> Bool {
        canAccessPatient(subject: subject, patientId: visit.patientId) || visit.bookedBy == subject
    }

    private func loadVisit(_ visitId: String) throws -> VisitRecord {
        guard let visit = state.clinic.visit(visitId) else { throw ClinicError.visitNotFound }
        return visit
    }

    /// `patient_visit`.
    func patientVisit(_ visitId: String) throws -> VisitRecord {
        let subject = try requirePatient()
        let visit = try loadVisit(visitId)
        guard patientMaySee(subject: subject, visit) else {
            throw ClinicError(
                status: 403, code: "forbidden", message: "This visit belongs to someone else.")
        }
        return visit
    }

    // Shared checks

    /// `_refuse_after_emergency`: the no-ticket red line belongs to the patient, not to one visit.
    private func refuseAfterEmergency(_ patientId: String, otherThan: String? = nil) throws {
        guard let visitId = VisitFlow.emergencyToday(
            state.clinic, patientId: patientId, now: clock(), otherThan: otherThan)
        else { return }
        throw ClinicError(
            status: 409, code: "emergency_today", message: visitsText.staffRouteEn,
            messageAr: visitsText.staffRouteAr, extra: ["visit_id": .string(visitId)])
    }

    /// `_refuse_active_visit`: one queue place per patient. A dependent has their own.
    private func refuseActiveVisit(_ patientId: String, otherThan: String? = nil) throws {
        let found = state.clinic.visits.last {
            $0.patientId == patientId && constants.activeStatuses.contains($0.status)
                && $0.id != otherThan
        }
        guard let found else { return }
        throw ClinicError(
            status: 409, code: "active_visit",
            message: "This patient already has a visit in progress.",
            extra: ["visit_id": .string(found.id)])
    }

    private func confirmed(_ visitId: String) -> Bool {
        state.chats[visitId]?.confirmedByPatient ?? false
    }

    /// `_confirm_intake`. Only `service` is honoured from the answers.
    private func confirmIntakeRow(_ visitId: String, service wanted: String?) throws -> ConfirmResponse {
        let visit = try loadVisit(visitId)
        guard visit.status == .intake else { throw ClinicError.visitNotInIntake }
        guard let effective = state.chats[visitId]?.intake else {
            throw ClinicError(status: 409, code: "no_intake", message: "This visit has no intake yet.")
        }
        let chosen = wanted ?? (visit.service ?? effective.service).rawValue
        guard let service = Service(rawValue: chosen) else {
            throw ClinicError(
                status: 422, code: "unknown_service", message: "We do not know this service.")
        }
        state.chats[visitId]?.confirmedByPatient = true
        state.clinic.updateVisit(visitId) { $0.service = service }
        state.audit(
            visitId,
            [AiEvent(type: "intake.confirmed", payload: ["service": .string(service.rawValue)])],
            at: clock())
        return ConfirmResponse(status: visit.status, service: service, intake: effective.patientView)
    }

    // Views

    private func centreName(_ centreId: String?) -> Centre? {
        centreId.flatMap { state.clinic.centre($0) }.map {
            Centre(id: $0.id, nameEn: $0.nameEn, nameAr: $0.nameAr)
        }
    }

    /// `_shown_ticket`.
    private func shownTicket(_ visit: VisitRecord) -> TicketRecord? {
        if visit.status == .redirectedEmergency || visit.status == .expired { return nil }
        if let live = engine.liveTicket(state.clinic, visitId: visit.id) { return live }
        guard visit.status == .completed,
              let latest = engine.latestTicket(state.clinic, visitId: visit.id),
              latest.state == .done
        else { return nil }
        return latest
    }

    /// `_go_to`.
    private func goTo(_ ticket: Ticket?) -> GoTo? {
        guard let ticket, constants.atACounter.contains(ticket.state) else { return nil }
        return GoTo(counter: ticket.counter, counterAr: ticket.counterAr)
    }

    /// `_emergency_card`.
    private func emergencyCard(_ visit: VisitRecord, _ chat: ChatRecord) throws -> EmergencyCard? {
        guard visit.status == .redirectedEmergency else { return nil }
        let last = chat.lastTurn?.emergency == true ? chat.lastTurn : nil  // A nurse sent them.
        let selfHarm = last?.selfHarm ?? false
        let reply = last?.reply ?? ""
        guard let nearestEd = CentreRules.nearestEd(state.clinic, patientId: visit.patientId) else {
            throw ClinicError.internalError
        }
        return EmergencyCard(
            reply: reply.isEmpty ? Scripted.emergencyReply(lang: chat.language, selfHarm: selfHarm) : reply,
            replyEn: Scripted.emergencyReply(lang: "en", selfHarm: selfHarm),
            replyAr: Scripted.emergencyReply(lang: "ar", selfHarm: selfHarm),
            selfHarm: selfHarm, nearestEd: nearestEd)
    }

    /// `_rating`: the first one stands.
    private func rating(_ visitId: String) -> Int? {
        let row = state.clinic.events.first { $0.visitId == visitId && $0.type == "visit.rated" }
        guard case .object(let payload)? = row?.payload, case .number(let stars)? = payload["stars"]
        else { return nil }
        return Int(stars)
    }

    private func medicines(_ visitId: String) -> VisitMedicines {
        VisitMedicines(
            en: MedicineLines.forVisit(state.clinic, visitId: visitId, lang: "en"),
            ar: MedicineLines.forVisit(state.clinic, visitId: visitId, lang: "ar"))
    }

    // backend/routers/auth.py

    private func patient(qid: String) throws -> Patient {
        guard let patient = MockHealth.findByQid(state.clinic, qid: qid, now: clock()) else {
            throw ClinicError(status: 404, code: "unknown_qid", message: "No demo patient has this QID.")
        }
        return patient
    }

    public func authStart(qid: String) throws -> AuthStartResponse {
        catchUp()
        defer { settle() }
        _ = try patient(qid: qid)
        return AuthStartResponse(otpSent: true)
    }

    public func authVerify(qid: String, otp: String) throws -> Patient {
        try routeVerify(qid: qid, otp: otp)
    }

    func routeVerify(qid: String, otp: String?) throws -> Patient {
        catchUp()
        defer { settle() }
        guard let otp else { throw Self.invalidRequest }
        let patient = try patient(qid: qid)
        guard ClinicText.same(otp, constants.demoOtp) else {
            throw ClinicError(status: 401, code: "invalid_otp", message: "That code is not correct.")
        }
        state.subject = SessionSubject(kind: .patient, id: patient.id)
        return patient
    }

    public func demoPatients() -> [DemoPatient] {
        catchUp()
        defer { settle() }
        return MockHealth.demoPatients(state.clinic)
    }

    /// Always simulated: there is no model on the phone and the footer must stay honest. The
    /// load is on because the Dockerfile sets it.
    public func health() -> Health {
        catchUp()
        settle()
        return Health(status: "ok", aiMode: .simulated, simulateLoad: true)
    }

    public func getMe() throws -> Me {
        catchUp()
        defer { settle() }
        let subject = try requirePatient()
        guard let patient = MockHealth.patient(state.clinic, id: subject, on: today),
              let record = MockHealth.record(state.clinic, patientId: subject)
        else { throw ClinicError.internalError }
        return Me(
            patient: patient,
            dependents: MockHealth.dependents(state.clinic, guardianId: subject, on: today),
            record: record)
    }

    public var isSignedIn: Bool { state.subject != nil }

    /// Open streams end here: a screen left on one would otherwise read nothing but refusals.
    public func signOut() {
        catchUp()
        state.subject = nil
        settle()
        dropStreams()
    }

    // Starting a visit

    public func createVisit(patientId: String?) throws -> CreateVisitResponse {
        try routeCreateVisit(consent: true, patientId: patientId)
    }

    func routeCreateVisit(consent: Bool, patientId: String?) throws -> CreateVisitResponse {
        catchUp()
        defer { settle() }
        let subject = try requirePatient()
        guard consent else {
            throw ClinicError(
                status: 422, code: "consent_required",
                message: "Consent is needed before the chat starts.")
        }
        let target = (patientId ?? "").isEmpty ? subject : patientId ?? subject
        guard canAccessPatient(subject: subject, patientId: target) else {
            throw ClinicError(
                status: 403, code: "forbidden", message: "You cannot start a visit for this patient.")
        }
        let visitId = newId("V")
        let now = clock()
        try refuseActiveVisit(target)
        try refuseAfterEmergency(target)
        state.clinic.visits.append(
            VisitRecord(
                id: visitId, patientId: target, createdAt: ClinicTime.iso(now), bookedBy: subject))
        state.audit(
            visitId,
            [
                AiEvent(
                    type: "consent.given",
                    payload: ["patient_id": .string(target), "booked_by": .string(subject)])
            ],
            at: now)
        let (chat, status) = try state.history(visitId: visitId, on: today)
        return CreateVisitResponse(
            visitId: visitId, status: status, language: chat.language,
            opening: chat.messages[0].content)
    }

    public func listVisits() throws -> [VisitRow] {
        catchUp()
        defer { settle() }
        let subject = try requirePatient()
        let dependents = state.clinic.dependentLinks.filter { $0.guardianId == subject }
            .map(\.dependentId)
        let rows = state.clinic.visits.enumerated()
            .filter { $0.element.patientId == subject || dependents.contains($0.element.patientId) }
            .sorted { first, second in
                first.element.createdAt != second.element.createdAt
                    ? first.element.createdAt > second.element.createdAt
                    : first.offset > second.offset
            }
        return rows.map { row in
            let visit = row.element
            return VisitRow(
                visitId: visit.id, patientId: visit.patientId, status: visit.status,
                stage: visit.status.stage, service: visit.service, centreId: visit.centreId,
                centre: centreName(visit.centreId), createdAt: visit.createdAt,
                completedAt: visit.completedAt,
                active: constants.activeStatuses.contains(visit.status))
        }
    }

    public func getVisit(visitId: String) throws -> Visit {
        catchUp()
        defer { settle() }
        let visit = try patientVisit(visitId)
        let (chat, status) = try state.history(visitId: visitId, on: today)
        let ticket = shownTicket(visit)
        let shown = try ticket.map { try engine.ticketView(&state.clinic, ticket: $0) }
        return Visit(
            visitId: visitId, patientId: visit.patientId, bookedBy: visit.bookedBy, status: status,
            stage: status.stage, service: visit.service, createdAt: visit.createdAt,
            arrivedAt: visit.arrivedAt, completedAt: visit.completedAt,
            centre: centreName(visit.centreId), ticket: shown,
            intake: chat.intake?.patientView, confirmedByPatient: confirmed(visitId),
            chat: VisitChat(messages: chat.messages, language: chat.language),
            medicines: medicines(visitId), emergency: try emergencyCard(visit, chat),
            goTo: goTo(shown),
            refill: visit.status == .deflectedRefill ? chat.lastTurn?.refill : nil,
            rating: rating(visitId))
    }

    // The chat

    public func sendChat(visitId: String, text: String) throws -> ChatResponse {
        try routeChat(visitId: visitId, text: text)
    }

    /// `send_message`. Past arrival the rules still run: a patient in the waiting room can get
    /// worse. `transcript` is always nil, because voice is transcribed on the phone.
    func routeChat(visitId: String, text: String?) throws -> ChatResponse {
        catchUp()
        defer { settle() }
        let visit = try patientVisit(visitId)
        guard let text else { throw ClinicError.invalidText }
        let now = clock()
        let result: TurnResult
        if constants.atTheCentre.contains(try loadVisit(visitId).status) {
            result = try state.redFlagPastArrival(
                visitId: visitId, message: text, on: .instant(now), now: now)
        } else {
            result = try state.handleMessage(
                visitId: visitId, text: text, on: .instant(now), now: now)
        }
        if result.emergency {
            try VisitFlow.leaveTheQueue(&engine, &state.clinic, patientId: visit.patientId)
            cancelDemoRuns(patientId: visit.patientId)
        }
        return result.toAPI(
            status: try loadVisit(visitId).status,
            nearestEd: result.emergency
                ? CentreRules.nearestEd(state.clinic, patientId: visit.patientId) : nil)
    }

    // After the chat

    public func confirmIntake(visitId: String, service: Service?) throws -> ConfirmResponse {
        try routeConfirm(visitId: visitId, service: service?.rawValue)
    }

    func routeConfirm(visitId: String, service: String?) throws -> ConfirmResponse {
        catchUp()
        defer { settle() }
        _ = try patientVisit(visitId)
        return try confirmIntakeRow(visitId, service: service)
    }

    public func continueRefill(visitId: String) throws -> ConfirmResponse {
        catchUp()
        defer { settle() }
        _ = try patientVisit(visitId)
        let now = clock()
        try state.continueAfterRefill(visitId: visitId, on: .instant(now), now: now)
        return try confirmIntakeRow(visitId, service: Service.gp.rawValue)
    }

    /// Logs and still gives no ticket. There is no path from here to the queue.
    public func emergencyOverride(visitId: String) throws -> OverrideResponse {
        catchUp()
        defer { settle() }
        let visit = try patientVisit(visitId)
        guard visit.status == .redirectedEmergency else {
            throw ClinicError(
                status: 409, code: "not_emergency", message: "This visit is not an emergency.")
        }
        state.audit(visitId, [AiEvent(type: "emergency.override", payload: [:])], at: clock())
        return OverrideResponse(
            status: .redirectedEmergency, ticket: nil, message: visitsText.staffRouteEn,
            messageAr: visitsText.staffRouteAr)
    }

    // Centres

    public func listCentres(
        service: String, visitId: String, lat: Double?, lng: Double?
    ) throws -> CentreList {
        try routeCentres(service: service, visitId: visitId, lat: lat, lng: lng)
    }

    /// `list_centres`. With no visit, the account holder's own map.
    func routeCentres(
        service: String, visitId: String?, lat: Double?, lng: Double?
    ) throws -> CentreList {
        catchUp()
        defer { settle() }
        let subject = try requirePatient()
        guard Self.inRange(lat, 90), Self.inRange(lng, 180) else { throw Self.invalidRequest }
        guard service == "emergency" || Service(rawValue: service) != nil else {
            throw ClinicError(
                status: 422, code: "unknown_service", message: "We do not know this service.")
        }
        let patientId = try visitId.map { try patientVisit($0).patientId } ?? subject
        return try CentreRules.list(
            state.clinic, engine: engine, patientId: patientId, service: service, lat: lat, lng: lng)
    }

    /// `Field(ge=-limit, le=limit)`, which also refuses a NaN.
    private static func inRange(_ value: Double?, _ limit: Double) -> Bool {
        value.map { (-limit...limit).contains($0) } ?? true
    }

    public func reserve(visitId: String, centreId: String) throws -> ReserveResponse {
        try routeReserve(visitId: visitId, centreId: centreId)
    }

    func routeReserve(visitId: String, centreId: String?) throws -> ReserveResponse {
        catchUp()
        defer { settle() }
        let visit = try patientVisit(visitId)
        guard let centreId else { throw Self.invalidRequest }
        guard let centre = state.clinic.centre(centreId) else {
            throw ClinicError(status: 404, code: "unknown_centre", message: "No centre has this ID.")
        }
        guard confirmed(visitId) else {
            throw ClinicError(
                status: 409, code: "intake_not_confirmed", message: "Confirm your answers first.")
        }
        guard let service = visit.service?.rawValue,
              centre.services.contains(CentreRules.routedService(service))
        else {
            throw ClinicError(
                status: 409, code: "service_not_offered",
                message: "This centre does not offer this service.")
        }
        try refuseAfterEmergency(visit.patientId, otherThan: visitId)
        try refuseActiveVisit(visit.patientId, otherThan: visitId)
        let ticket = try engine.issueTicket(
            &state.clinic, visitId: visitId,
            counterId: try engine.triageCounter(state.clinic, centreId: centre.id))
        let shown = try engine.ticketView(&state.clinic, ticket: ticket)
        guard let expiresAt = shown.expiresAt else { throw ClinicError.internalError }
        return ReserveResponse(
            ticket: shown, expiresAt: expiresAt, checkInValidMin: constants.reservationMinutes,
            message: visitsText.checkInEn, messageAr: visitsText.checkInAr)
    }

    // Arriving

    /// `Arrive`, the request model. `ArriveBody` can only spell the valid forms of it.
    struct ArrivalRequest {
        var lat: Double?
        var lng: Double?
        var qrCode: String?
        var button: Bool?

        init(lat: Double? = nil, lng: Double? = nil, qrCode: String? = nil, button: Bool? = nil) {
            self.lat = lat
            self.lng = lng
            self.qrCode = qrCode
            self.button = button
        }

        init(_ body: ArriveBody) {
            switch body {
            case .button: self.init(button: true)
            case .location(let lat, let lng): self.init(lat: lat, lng: lng)
            case .qrCode(let code): self.init(qrCode: code)
            }
        }
    }

    /// `_arrival_method`.
    private func arrivalMethod(_ body: ArrivalRequest) throws -> String {
        func refused(_ message: String) -> ClinicError {
            ClinicError(status: 422, code: "arrival_method_required", message: message)
        }
        if (body.lat == nil) != (body.lng == nil) { throw refused("Send both lat and lng.") }
        var methods: [String] = []
        if body.lat != nil { methods.append("geofence") }
        if body.qrCode != nil { methods.append("qr") }
        if body.button == true { methods.append("button") }
        guard methods.count == 1, let method = methods.first else {
            throw refused("Send exactly one of a location, a door code or the button.")
        }
        return method
    }

    /// `_check_at_centre`.
    private func checkAtCentre(_ body: ArrivalRequest, method: String, centreId: String) throws {
        if method == "geofence", let lat = body.lat, let lng = body.lng,
           let centre = state.clinic.centre(centreId) {
            let distance = ClinicGeo.distanceM(lat, lng, centre.lat, centre.lng)
            if distance > Double(constants.geofenceM) {
                throw ClinicError(
                    status: 409, code: "too_far", message: "You are not at the centre yet.",
                    extra: ["distance_m": .number(Double(ClinicGeo.roundedMetres(distance)))])
            }
        } else if method == "qr", !ClinicText.same(body.qrCode ?? "", "DOOR-\(centreId)") {
            throw ClinicError(
                status: 409, code: "wrong_door",
                message: "This door code belongs to another centre.")
        }
    }

    public func arrive(visitId: String, body: ArriveBody) throws -> ArriveResponse {
        try routeArrive(visitId: visitId, body: ArrivalRequest(body))
    }

    func routeArrive(visitId: String, body: ArrivalRequest) throws -> ArriveResponse {
        catchUp()
        defer { settle() }
        let visit = try patientVisit(visitId)
        guard Self.inRange(body.lat, 90), Self.inRange(body.lng, 180) else {
            throw Self.invalidRequest
        }
        let method = try arrivalMethod(body)
        try engine.expireDue(&state.clinic)
        let found = engine.liveTicket(state.clinic, visitId: visitId)
            ?? engine.latestTicket(state.clinic, visitId: visitId)
        guard let ticket = found else {
            throw ClinicError(status: 409, code: "no_reservation", message: "This visit has no reservation.")
        }
        try refuseAfterEmergency(visit.patientId, otherThan: visitId)
        if ticket.state == .reserved {  // Any other ticket: the engine gives the real reason.
            try checkAtCentre(body, method: method, centreId: ticket.centreId)
        }
        let activated = try engine.activate(&state.clinic, ticketId: ticket.id, method: method)
        startDemoRun(visitId: visitId, ticket: activated)
        let shown = try engine.ticketView(&state.clinic, ticket: activated)
        return ArriveResponse(ticket: shown, goTo: goTo(shown))
    }

    // After the visit

    public func rateVisit(visitId: String, stars: Int) throws -> RatingResponse {
        try routeRate(visitId: visitId, stars: stars)
    }

    /// An event row only: the visit, its tickets and the stats stay as they are.
    func routeRate(visitId: String, stars: Int?) throws -> RatingResponse {
        catchUp()
        defer { settle() }
        _ = try patientVisit(visitId)
        guard let stars, (1...5).contains(stars) else { throw Self.invalidRequest }
        guard try loadVisit(visitId).status == .completed else {
            throw ClinicError(
                status: 409, code: "visit_not_completed",
                message: "Only a completed visit can be rated.")
        }
        guard rating(visitId) == nil else {
            throw ClinicError(
                status: 409, code: "already_rated", message: "This visit has already been rated.")
        }
        state.audit(
            visitId, [AiEvent(type: "visit.rated", payload: ["stars": .number(Double(stars))])],
            at: clock())
        return RatingResponse(rating: stars)
    }
}
