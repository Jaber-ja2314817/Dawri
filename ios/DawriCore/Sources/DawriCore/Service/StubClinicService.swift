import Foundation

/// TEMPORARY, Phase 1 only. A stand-in for `LocalClinicService`, so the app can build and show
/// a screen at any stage before the real on-device clinic exists. Delete it when that lands.
///
/// All data is canned and synthetic. The chat follows a fixed script per patient and never
/// reads the message, so nothing here is an emergency rule. It makes no network call.
public actor StubClinicService: ClinicService {
    /// The id of the visit `init(stage:)` starts with.
    public static let startingVisitId = "V_stub_1"

    private var patientId: String?
    private var visits: [String: Visit] = [:]
    private var order: [String] = []
    private var listeners: [String: [AsyncStream<VisitUpdate>.Continuation]] = [:]
    private var nextVisit = 2

    /// Signed out with no visits, ready for the login screen.
    public init() {}

    /// Already signed in as `patientId`, with one visit at `stage`.
    public init(patientId: String = "P001", stage: VisitStage, confirmedByPatient: Bool = false) {
        self.patientId = patientId
        let visit = Self.visit(
            id: Self.startingVisitId, patientId: patientId, bookedBy: patientId,
            stage: stage, confirmed: confirmedByPatient)
        visits[visit.visitId] = visit
        order = [visit.visitId]
    }

    // Moving a visit by hand

    /// Takes a visit one step on, as staff would, and tells its listeners.
    public func advance(visitId: String) throws {
        let visit = try stored(visitId)
        let confirmed: Bool
        let next: VisitStage
        switch visit.stage {
        case .intake:
            (next, confirmed) = visit.confirmedByPatient ? (.reserved, true) : (.intake, true)
        case .reserved: (next, confirmed) = (.triage, true)
        case .triage: (next, confirmed) = (.doctor, true)
        case .doctor: (next, confirmed) = (.pharmacy, true)
        case .pharmacy: (next, confirmed) = (.completed, true)
        case .expired: (next, confirmed) = (.reserved, true)
        case .emergency, .refill, .completed, .cancelled:
            throw ClinicError(
                status: 409, code: "invalid_transition", message: "No next step for this visit.")
        }
        store(Self.moved(visit, to: next, confirmed: confirmed))
    }

    /// Ends the live updates of a visit, as a lost connection would.
    public func dropUpdates(visitId: String) {
        for listener in listeners[visitId] ?? [] {
            listener.yield(.dropped)
            listener.finish()
        }
        listeners[visitId] = nil
    }

    // ClinicService

    public func authStart(qid: String) throws -> AuthStartResponse {
        _ = try patient(qid: qid)
        return AuthStartResponse(otpSent: true)
    }

    public func authVerify(qid: String, otp: String) throws -> Patient {
        let patient = try patient(qid: qid)
        guard otp == "0000" else {
            throw ClinicError(status: 401, code: "invalid_otp", message: "That code is not correct.")
        }
        patientId = patient.id
        return patient
    }

    public func demoPatients() -> [DemoPatient] {
        Self.patients.prefix(3).map {
            DemoPatient(
                id: $0.id, qidDemo: $0.qidDemo, fullNameEn: $0.fullNameEn, fullNameAr: $0.fullNameAr)
        }
    }

    public func health() -> Health {
        Health(status: "ok", aiMode: .simulated, simulateLoad: false)
    }

    public func getMe() throws -> Me {
        let patient = try signedInPatient()
        let dependents = patient.id == "P001"
            ? Self.patients.filter { $0.id == "P004" || $0.id == "P005" } : []
        return Me(
            patient: patient, dependents: dependents,
            record: .object(["demo": .bool(true), "resourceType": .string("Bundle")]))
    }

    public func createVisit(patientId visitor: String?) throws -> CreateVisitResponse {
        let account = try signedInPatient()
        let id = "V_stub_\(nextVisit)"
        nextVisit += 1
        let visit = Self.visit(
            id: id, patientId: visitor ?? account.id, bookedBy: account.id,
            stage: .intake, confirmed: false)
        order.append(id)
        store(visit)
        return CreateVisitResponse(
            visitId: id, status: visit.status, language: visit.chat.language,
            opening: visit.chat.messages[0].content)
    }

    public func listVisits() throws -> [VisitRow] {
        _ = try signedInPatient()
        return order.reversed().compactMap { visits[$0] }.map { visit in
            VisitRow(
                visitId: visit.visitId, patientId: visit.patientId, status: visit.status,
                stage: visit.stage, service: visit.service, centreId: visit.centre?.id,
                centre: visit.centre, createdAt: visit.createdAt, completedAt: visit.completedAt,
                active: [.reserved, .triage, .doctor, .pharmacy].contains(visit.stage))
        }
    }

    public func getVisit(visitId: String) throws -> Visit {
        try stored(visitId)
    }

    public func sendChat(visitId: String, text: String) throws -> ChatResponse {
        var visit = try stored(visitId)
        guard visit.stage == .intake, !visit.confirmedByPatient else {
            throw ClinicError(
                status: 409, code: "visit_not_in_intake",
                message: "This visit is past the chat stage.")
        }
        visit.chat.messages.append(ChatMessage(role: .user, content: text, slot: nil))
        let turn = visit.chat.messages.count { $0.role == .user }
        let script = Self.script(language: visit.chat.language)

        switch visit.patientId {
        case "P002":
            var moved = Self.moved(visit, to: .refill, confirmed: false)
            moved.chat.messages.append(
                ChatMessage(role: .assistant, content: script.refill, slot: "summary"))
            store(moved)
            return response(
                reply: script.refill, status: moved.status, refill: moved.refill, source: "rules")
        case "P003":
            var moved = Self.moved(visit, to: .emergency, confirmed: false)
            moved.chat.messages.append(
                ChatMessage(role: .assistant, content: script.emergency, slot: "summary"))
            store(moved)
            return response(
                reply: script.emergency, status: moved.status, emergency: true,
                nearestEd: moved.emergency?.nearestEd, source: "rules")
        default:
            break
        }

        if turn < script.questions.count {
            let (question, slot) = script.questions[turn]
            visit.chat.messages.append(ChatMessage(role: .assistant, content: question, slot: slot))
            store(visit)
            return response(reply: question, status: visit.status, source: "simulated")
        }
        visit.chat.messages.append(
            ChatMessage(role: .assistant, content: script.summary, slot: "summary"))
        visit.intake = Self.intake(language: visit.chat.language)
        store(visit)
        return response(
            reply: script.summary, status: visit.status, done: true, intake: visit.intake,
            source: "simulated")
    }

    public func confirmIntake(visitId: String, service: Service?) throws -> ConfirmResponse {
        var visit = try stored(visitId)
        guard visit.stage == .intake else {
            throw ClinicError(
                status: 409, code: "visit_not_in_intake",
                message: "This visit is past the chat stage.")
        }
        guard let intake = visit.intake else {
            throw ClinicError(status: 409, code: "no_intake", message: "This visit has no intake yet.")
        }
        visit.confirmedByPatient = true
        visit.service = service ?? intake.service
        store(visit)
        return ConfirmResponse(status: visit.status, service: visit.service ?? .gp, intake: intake)
    }

    public func continueRefill(visitId: String) throws -> ConfirmResponse {
        let visit = try stored(visitId)
        guard visit.stage == .refill else {
            throw ClinicError(
                status: 409, code: "visit_not_deflected",
                message: "This visit was not sent to the refill route.")
        }
        let moved = Self.moved(visit, to: .intake, confirmed: true)
        store(moved)
        return ConfirmResponse(status: moved.status, service: .gp, intake: moved.intake)
    }

    public func emergencyOverride(visitId: String) throws -> OverrideResponse {
        guard try stored(visitId).stage == .emergency else {
            throw ClinicError(
                status: 409, code: "not_emergency", message: "This visit is not an emergency.")
        }
        return OverrideResponse(
            status: .redirectedEmergency, ticket: nil,
            message: "Speak to a member of staff at the centre, or call 999",
            messageAr: "تحدث إلى أحد الموظفين في المركز، أو اتصل بـ 999")
    }

    public func listCentres(
        service: String, visitId: String, lat: Double?, lng: Double?
    ) throws -> CentreList {
        let visit = try stored(visitId)
        let home = Self.patient(id: visit.patientId).registeredCentre.id
        let centres = Self.centreOptions
            .map { option in
                var option = option
                option.registered = option.id == home
                return option
            }
            .sorted { $0.registered && !$1.registered }
        return CentreList(
            service: service, effectiveService: service, serviceFallback: false,
            defaultCentreId: home, centres: centres, suggestion: nil)
    }

    public func reserve(visitId: String, centreId: String) throws -> ReserveResponse {
        let visit = try stored(visitId)
        guard visit.confirmedByPatient, visit.stage == .intake || visit.stage == .expired else {
            throw ClinicError(
                status: 409, code: "intake_not_confirmed", message: "Confirm your answers first.")
        }
        guard let centre = Self.centreOptions.first(where: { $0.id == centreId }) else {
            throw ClinicError(
                status: 404, code: "unknown_centre", message: "We could not find this centre.")
        }
        var moved = Self.moved(visit, to: .reserved, confirmed: true)
        moved.centre = Centre(id: centre.id, nameEn: centre.nameEn, nameAr: centre.nameAr)
        moved.ticket?.centreId = centre.id
        store(moved)
        guard let ticket = moved.ticket, let expiresAt = ticket.expiresAt else {
            preconditionFailure("A reserved stub visit always has a ticket that expires")
        }
        return ReserveResponse(
            ticket: ticket, expiresAt: expiresAt, checkInValidMin: 45,
            message: "Check-in valid for 45 minutes", messageAr: "تسجيل الوصول صالح لمدة 45 دقيقة")
    }

    public func arrive(visitId: String, body: ArriveBody) throws -> ArriveResponse {
        let visit = try stored(visitId)
        guard visit.stage == .reserved else {
            throw ClinicError(
                status: 409, code: "no_reservation", message: "This visit has no reservation.")
        }
        let moved = Self.moved(visit, to: .triage, confirmed: true)
        store(moved)
        guard let ticket = moved.ticket else {
            preconditionFailure("A stub visit at triage always has a ticket")
        }
        return ArriveResponse(ticket: ticket, goTo: moved.goTo)
    }

    public func rateVisit(visitId: String, stars: Int) throws -> RatingResponse {
        var visit = try stored(visitId)
        guard visit.stage == .completed else {
            throw ClinicError(
                status: 409, code: "visit_not_completed",
                message: "Only a completed visit can be rated.")
        }
        guard visit.rating == nil else {
            throw ClinicError(
                status: 409, code: "already_rated", message: "This visit has already been rated.")
        }
        guard (1...5).contains(stars) else {
            throw ClinicError(
                status: 422, code: "invalid_request",
                message: "The request body or parameters are not valid.")
        }
        visit.rating = stars
        store(visit)
        return RatingResponse(rating: stars)
    }

    public var isSignedIn: Bool { patientId != nil }

    public func signOut() {
        patientId = nil
    }

    public func visitUpdates(visitId: String) -> AsyncStream<VisitUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: VisitUpdate.self)
        continuation.yield(.open)
        listeners[visitId, default: []].append(continuation)
        return stream
    }

    // Private

    private func stored(_ visitId: String) throws -> Visit {
        guard let visit = visits[visitId] else {
            throw ClinicError(status: 404, code: "visit_not_found", message: "No visit has this ID.")
        }
        return visit
    }

    private func store(_ visit: Visit) {
        visits[visit.visitId] = visit
        for listener in listeners[visit.visitId] ?? [] {
            listener.yield(.changed)
        }
    }

    private func patient(qid: String) throws -> Patient {
        guard let patient = Self.patients.first(where: { $0.qidDemo == qid }) else {
            throw ClinicError(status: 404, code: "unknown_qid", message: "No demo patient has this QID.")
        }
        return patient
    }

    private func signedInPatient() throws -> Patient {
        guard let patientId else {
            throw ClinicError(status: 401, code: "unauthorized", message: "Log in first.")
        }
        return Self.patient(id: patientId)
    }

    private func response(
        reply: String, status: VisitStatus, done: Bool = false, emergency: Bool = false,
        intake: Intake? = nil, refill: RefillMedicine? = nil, nearestEd: NearestEd? = nil,
        source: String
    ) -> ChatResponse {
        ChatResponse(
            reply: reply, done: done, emergency: emergency, intake: intake, refill: refill,
            denied: [], aiSource: source, selfHarm: false, status: status, transcript: nil,
            nearestEd: nearestEd)
    }

    // Canned data

    private struct Script {
        let questions: [(text: String, slot: String)]
        let summary: String
        let refill: String
        let emergency: String
    }

    private static func script(language: String) -> Script {
        language == "ar"
            ? Script(
                questions: [
                    ("شو اللي يتعبك اليوم؟", "complaint"),
                    ("كم شدته من 0 إلى 10؟", "severity"),
                    ("أخذت أي دوا له؟", "medicine"),
                    ("في شي ثاني تبي الممرضة تعرفه؟", "other"),
                ],
                summary: "شكرا. هذا اللي بقوله للممرضة: حرارة وكحة، 3 أيام، الشدة 6 من 10، أخذت باراسيتامول. هل هذا صحيح؟",
                refill: "دواك المعتاد (amlodipine 5 mg once daily) ما يحتاج زيارة. راسل خط إعادة الصرف في مركزك.",
                emergency: "هذا يحتاج رعاية عاجلة. توجه الآن إلى أقرب قسم طوارئ، أو اتصل على 999.")
            : Script(
                questions: [
                    ("What brings you in today?", "complaint"),
                    ("How bad is it from 0 to 10?", "severity"),
                    ("Did you take any medicine for it?", "medicine"),
                    ("Anything else the nurse should know?", "other"),
                ],
                summary: "Thanks. Here is what I will tell the nurse: fever and cough, 3 days, severity 6/10, took paracetamol. Is this right?",
                refill: "Your usual medicine (amlodipine 5 mg once daily) can be handled without a visit. Please message your centre's refill line.",
                emergency: "This needs urgent care. Please go to the nearest emergency department now, or call 999.")
    }

    private static func intake(language: String) -> Intake {
        Intake(
            emergency: false, language: language, chiefComplaintPatientWords: "fever and cough",
            severity0To10: 6, selfMedication: ["paracetamol"], service: .gp,
            serviceConfidence: 0.85, refillRequest: nil, questionsAsked: 4, deniedRedFlags: [])
    }

    private static let wakra = Centre(
        id: "C-WAKRA", nameEn: "Al Wakra Health Centre", nameAr: "مركز الوكرة الصحي")

    private static func patient(id: String) -> Patient {
        guard let patient = patients.first(where: { $0.id == id }) else {
            preconditionFailure("The stub has no patient \(id)")
        }
        return patient
    }

    private static let patients: [Patient] = [
        Patient(
            id: "P001", qidDemo: "DEMO-10001", fullNameEn: "Fatima Al-Demo",
            fullNameAr: "فاطمة التجريبية", dob: "1992-03-14", age: 34, sex: "F",
            preferredLang: "ar", allergies: ["penicillin"], chronic: [], activeMeds: [],
            registeredCentre: wakra, demo: true),
        Patient(
            id: "P002", qidDemo: "DEMO-10002", fullNameEn: "Ahmed Al-Demo",
            fullNameAr: "أحمد التجريبي", dob: "1959-07-02", age: 67, sex: "M",
            preferredLang: "ar", allergies: [], chronic: ["hypertension"],
            activeMeds: ["amlodipine 5 mg once daily"],
            registeredCentre: Centre(
                id: "C-RAYYAN", nameEn: "Al Rayyan Health Centre", nameAr: "مركز الريان الصحي"),
            demo: true),
        Patient(
            id: "P003", qidDemo: "DEMO-10003", fullNameEn: "Ravi Demo", fullNameAr: "رافي",
            dob: "1981-11-20", age: 44, sex: "M", preferredLang: "en", allergies: [],
            chronic: ["type 2 diabetes"], activeMeds: ["metformin 500 mg twice daily"],
            registeredCentre: Centre(
                id: "C-AIRPORT", nameEn: "Airport Health Centre", nameAr: "مركز المطار الصحي"),
            demo: true),
        Patient(
            id: "P004", qidDemo: "DEMO-10004", fullNameEn: "Layla Al-Demo",
            fullNameAr: "ليلى التجريبية", dob: "2019-05-10", age: 7, sex: "F",
            preferredLang: "ar", allergies: [], chronic: [], activeMeds: [],
            registeredCentre: wakra, demo: true),
        Patient(
            id: "P005", qidDemo: "DEMO-10005", fullNameEn: "Mariam Al-Demo",
            fullNameAr: "مريم التجريبية", dob: "1948-02-21", age: 78, sex: "F",
            preferredLang: "ar", allergies: [], chronic: ["hypertension"],
            activeMeds: ["amlodipine 5 mg once daily"], registeredCentre: wakra, demo: true),
    ]

    private static let centreOptions: [CentreOption] = [
        CentreOption(
            id: "C-WAKRA", nameEn: "Al Wakra Health Centre", nameAr: "مركز الوكرة الصحي",
            operator: "PHCC", lat: 25.17302, lng: 51.59575, waitMin: 12, peopleAhead: 3,
            distanceKm: 10.1, registered: false),
        CentreOption(
            id: "C-RAYYAN", nameEn: "Al Rayyan Health Centre", nameAr: "مركز الريان الصحي",
            operator: "PHCC", lat: 25.27992, lng: 51.43243, waitMin: 16, peopleAhead: 4,
            distanceKm: 11.2, registered: false),
        CentreOption(
            id: "C-AIRPORT", nameEn: "Airport Health Centre", nameAr: "مركز المطار الصحي",
            operator: "PHCC", lat: 25.25580, lng: 51.55778, waitMin: 36, peopleAhead: 7,
            distanceKm: 8.5, registered: false),
    ]

    private static let medicines = VisitMedicines(
        en: [MedicineLine(
            drug: "DR-PARA", name: "Paracetamol",
            line: "Paracetamol (tablet): take 500 mg, every 6 hours when needed, for 3 days.")],
        ar: [MedicineLine(
            drug: "DR-PARA", name: "باراسيتامول",
            line: "باراسيتامول (أقراص): الجرعة 500 ملغ، كل 6 ساعات عند الحاجة، لمدة 3 أيام.")])

    private static func ticket(
        visitId: String, number: String?, state: TicketState, counter: (id: String, en: String, ar: String),
        peopleAhead: Int?, estWaitMin: Int?, expiresAt: String? = nil
    ) -> Ticket {
        Ticket(
            id: "tkt_\(visitId)", visitId: visitId, number: number, state: state,
            centreId: "C-WAKRA", counterId: counter.id, counter: counter.en, counterAr: counter.ar,
            peopleAhead: peopleAhead, estWaitMin: estWaitMin, expiresAt: expiresAt)
    }

    /// A consistent visit at any stage with any confirmed flag.
    private static func visit(
        id: String, patientId: String, bookedBy: String?, stage: VisitStage, confirmed: Bool
    ) -> Visit {
        let patient = patient(id: patientId)
        let language = patient.preferredLang
        let now = Date.now
        let triage = (id: "C-WAKRA-T1", en: "Triage 1", ar: "الفرز 1")
        let room = (id: "C-WAKRA-D4", en: "Room 4", ar: "غرفة 4")
        let pharmacy = (id: "C-WAKRA-P1", en: "Pharmacy", ar: "الصيدلية")
        let opening = script(language: language).questions[0]

        var visit = Visit(
            visitId: id, patientId: patientId, bookedBy: bookedBy, status: status(of: stage),
            stage: stage, service: nil, createdAt: Timestamp.string(from: now), arrivedAt: nil,
            completedAt: nil, centre: nil, ticket: nil, intake: nil, confirmedByPatient: confirmed,
            chat: VisitChat(
                messages: [ChatMessage(role: .assistant, content: opening.text, slot: opening.slot)],
                language: language),
            medicines: VisitMedicines(en: [], ar: []), emergency: nil, goTo: nil, refill: nil,
            rating: nil)

        if confirmed || ![.intake, .emergency, .refill, .cancelled].contains(stage) {
            visit.intake = intake(language: language)
            visit.service = .gp
        }
        if [.reserved, .expired, .triage, .doctor, .pharmacy, .completed].contains(stage) {
            visit.centre = wakra
        }
        if [.triage, .doctor, .pharmacy, .completed].contains(stage) {
            visit.arrivedAt = visit.createdAt
        }

        switch stage {
        case .intake, .expired, .cancelled:
            break
        case .emergency:
            let script = script(language: language)
            visit.emergency = EmergencyCard(
                reply: script.emergency,
                replyEn: Self.script(language: "en").emergency,
                replyAr: Self.script(language: "ar").emergency,
                selfHarm: false,
                nearestEd: NearestEd(
                    id: "H-HGH", nameEn: "Hamad General Hospital", nameAr: "مستشفى حمد العام",
                    lat: 25.29349, lng: 51.50222, distanceKm: 7.0))
        case .refill:
            visit.refill = RefillMedicine(medicine: "amlodipine 5 mg once daily")
        case .reserved:
            visit.ticket = ticket(
                visitId: id, number: nil, state: .reserved, counter: triage, peopleAhead: nil,
                estWaitMin: nil,
                expiresAt: Timestamp.string(from: now.addingTimeInterval(45 * 60)))
        case .triage:
            visit.ticket = ticket(
                visitId: id, number: "T-014", state: .active, counter: triage, peopleAhead: 3,
                estWaitMin: 12)
            visit.goTo = GoTo(counter: triage.en, counterAr: triage.ar)
        case .doctor:
            visit.ticket = ticket(
                visitId: id, number: "D-GP-023", state: .active, counter: room, peopleAhead: 0,
                estWaitMin: 0)
            visit.goTo = GoTo(counter: room.en, counterAr: room.ar)
        case .pharmacy:
            visit.ticket = ticket(
                visitId: id, number: "P-031", state: .active, counter: pharmacy, peopleAhead: 0,
                estWaitMin: 0)
            visit.goTo = GoTo(counter: pharmacy.en, counterAr: pharmacy.ar)
        case .completed:
            visit.ticket = ticket(
                visitId: id, number: "P-031", state: .done, counter: pharmacy, peopleAhead: nil,
                estWaitMin: nil)
            visit.medicines = medicines
            visit.completedAt = visit.createdAt
        }
        return visit
    }

    /// The visit at another stage. What it already said and where it was stay as they were.
    private static func moved(_ visit: Visit, to stage: VisitStage, confirmed: Bool) -> Visit {
        var moved = Self.visit(
            id: visit.visitId, patientId: visit.patientId, bookedBy: visit.bookedBy,
            stage: stage, confirmed: confirmed)
        moved.createdAt = visit.createdAt
        moved.chat = visit.chat
        if moved.centre != nil, let centre = visit.centre {
            moved.centre = centre
            moved.ticket?.centreId = centre.id
        }
        return moved
    }

    private static func status(of stage: VisitStage) -> VisitStatus {
        guard let status = VisitStatus.allCases.first(where: { $0.stage == stage }) else {
            preconditionFailure("Every stage has a status")
        }
        return status
    }
}
