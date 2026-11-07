/// What SQLite holds for the queue and the visit flow, as one value. Array order is rowid.
/// Chat and intake storage belongs to the service's own state around this one.
public struct ClinicState: Sendable, Codable, Equatable {
    public var centres: [CentreRecord]
    public var counters: [CounterRecord]
    public var staff: [StaffRecord]
    public var patients: [PatientRecord]
    public var dependentLinks: [DependentLink]
    public var drugs: [DrugRecord]
    public var visits: [VisitRecord] = []
    public var tickets: [TicketRecord] = []
    public var sequences: [NumberSequenceRecord] = []
    public var prescriptions: [PrescriptionRecord] = []
    public var events: [EventRecord] = []

    /// `seed_static`: the seed tables, in insertion order, with no queue state.
    public init(seed data: ClinicData = .bundled) {
        centres = data.tables.centres
        counters = data.tables.counters
        staff = data.tables.doctors + data.tables.staff
        patients = data.tables.patients
        dependentLinks = data.tables.dependents
        drugs = data.tables.drugs
    }

    /// `_seed` in backend/bootstrap.py: the static seed plus today's queue state. Nobody is
    /// listening yet, so what seeding published is dropped.
    public static func fresh(engine: inout QueueEngine, simulateLoad: Bool) throws -> ClinicState {
        var state = ClinicState()
        try SimulatedLoad.seedQueueState(&engine, &state, simulateLoad: simulateLoad)
        _ = engine.takeMessages()
        return state
    }

    /// `_stale` in backend/bootstrap.py: true unless `today` is the only day on record.
    public func isStale(today: String) -> Bool {
        Set(sequences.map(\.day)) != [today]
    }

    func ticket(_ id: String) -> TicketRecord? {
        tickets.first { $0.id == id }
    }

    func counter(_ id: String) -> CounterRecord? {
        counters.first { $0.id == id }
    }

    func centre(_ id: String) -> CentreRecord? {
        centres.first { $0.id == id }
    }

    func visit(_ id: String) -> VisitRecord? {
        visits.first { $0.id == id }
    }

    func patient(_ id: String) -> PatientRecord? {
        patients.first { $0.id == id }
    }

    func staffMember(_ id: String) -> StaffRecord? {
        staff.first { $0.id == id }
    }

    /// `_load`.
    func loadTicket(_ id: String) throws -> TicketRecord {
        guard let found = ticket(id) else { throw ClinicError.ticketNotFound("no ticket \(id)") }
        return found
    }

    /// `_counter`.
    func loadCounter(_ id: String) throws -> CounterRecord {
        guard let found = counter(id) else { throw ClinicError.invalidTransition("no counter \(id)") }
        return found
    }

    func visitStatus(_ id: String?) -> VisitStatus? {
        id.flatMap { visit($0)?.status }
    }

    /// `_active`. ORDER BY priority DESC, activated_at ASC, seq ASC, with rowid under them
    /// because SQLite reads this from ix_ticket_queue.
    func activeTickets(at counterId: String) -> [TicketRecord] {
        queueOrdered(tickets.filter { $0.counterId == counterId && $0.state == .active })
    }

    func queueOrdered(_ rows: [TicketRecord]) -> [TicketRecord] {
        rows.enumerated().sorted { first, second in
            let (a, b) = (first.element, second.element)
            if a.priority != b.priority { return a.priority > b.priority }
            let (stampA, stampB) = (a.activatedAt ?? "", b.activatedAt ?? "")
            if stampA != stampB { return stampA < stampB }
            let (seqA, seqB) = (a.seq ?? .min, b.seq ?? .min)
            if seqA != seqB { return seqA < seqB }
            return first.offset < second.offset
        }.map(\.element)
    }

    /// `_called_count`.
    func calledCount(at counterId: String) -> Int {
        tickets.count { $0.counterId == counterId && $0.state == .called }
    }

    /// `_people_ahead`.
    func peopleAhead(_ ticket: TicketRecord) -> Int? {
        switch ticket.state {
        case .called, .serving:
            return 0
        case .active:
            let order = activeTickets(at: ticket.counterId)
            guard let place = order.firstIndex(where: { $0.id == ticket.id }) else { return nil }
            return calledCount(at: ticket.counterId) + place
        default:
            return nil
        }
    }

    /// `_has_live_ticket`.
    func hasLiveTicket(visitId: String) -> Bool {
        tickets.contains { $0.visitId == visitId && $0.state.isLive }
    }

    /// `_triage_counter`: the lowest id wins.
    func triageCounter(centreId: String) -> CounterRecord? {
        counters
            .filter { $0.centreId == centreId && $0.stage == .triage }
            .min { $0.id < $1.id }
    }

    mutating func updateTicket(_ id: String, _ change: (inout TicketRecord) -> Void) {
        guard let index = tickets.firstIndex(where: { $0.id == id }) else { return }
        change(&tickets[index])
    }

    /// An UPDATE on a row that may not exist, as for a simulated ticket's missing visit.
    mutating func updateVisit(_ id: String?, _ change: (inout VisitRecord) -> Void) {
        guard let id, let index = visits.firstIndex(where: { $0.id == id }) else { return }
        change(&visits[index])
    }

    /// `audit.record`, for one row.
    public mutating func appendEvent(visitId: String?, type: String, payload: JSONValue, at: String) {
        events.append(EventRecord(visitId: visitId, type: type, payload: payload, at: at))
    }
}

extension TicketState {
    /// `_LIVE_STATES`.
    var isLive: Bool {
        switch self {
        case .reserved, .active, .called, .serving: true
        case .done, .released, .expired: false
        }
    }
}
