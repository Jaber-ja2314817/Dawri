import Foundation

/// Port of `SqliteQueueEngine` in backend/queue_engine.py, deterministic on an injected clock
/// and id generator. Nothing outside the centre rules can reorder the queue, so no method takes
/// a priority or a position.
///
/// Every operation commits or rolls back as one, and `_expire` commits on its own first, so a
/// lapse survives the refusal that follows it, as `activate` relies on. What the backend would
/// have published collects in `outbox`, also when a later step throws: call `takeMessages`
/// after each operation and read the visit channels to drive `visitUpdates`.
public struct QueueEngine: Sendable {
    public let clock: @Sendable () -> Date
    public let newId: @Sendable (String) -> String
    public private(set) var outbox: [QueueMessage] = []

    static var constants: ClinicData.Constants { ClinicData.bundled.constants }
    static var noTicketStatuses: [VisitStatus] { constants.noTicketStatuses }
    static var reservationWindow: Int64 { Int64(constants.reservationMinutes) * 60 * 1_000_000 }

    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        newId: @escaping @Sendable (String) -> String = QueueEngine.randomId
    ) {
        self.clock = clock
        self.newId = newId
    }

    /// `db.new_id`.
    public static func randomId(prefix: String) -> String {
        let hex = UUID().uuidString.lowercased().filter { $0 != "-" }
        return "\(prefix)_\(hex.prefix(12))"
    }

    /// Hands over what has been published since the last call.
    public mutating func takeMessages() -> [QueueMessage] {
        defer { outbox = [] }
        return outbox
    }

    /// `_unit`. The body must reach everything through `unit`, not through `self`.
    private mutating func transaction<Value>(
        _ state: inout ClinicState, at now: Date,
        _ body: (inout QueueUnit) throws -> Value
    ) throws -> Value {
        var unit = QueueUnit(state: state, now: now, newId: newId)
        let value = try body(&unit)
        try unit.announceQueueChange()
        state = unit.state
        outbox += unit.messages
        return value
    }

    // Reserving and arriving

    /// Reserves remotely. A reserved ticket has no number and no place.
    public mutating func issueTicket(
        _ state: inout ClinicState, visitId: String, counterId: String
    ) throws -> TicketRecord {
        let now = clock()
        try expire(&state, now)
        return try transaction(&state, at: now) { unit in
            let counter = try unit.state.loadCounter(counterId)
            guard counter.stage == .triage else {
                throw ClinicError.invalidTransition("reservations are for triage counters only")
            }
            guard let status = unit.state.visitStatus(visitId) else {
                throw ClinicError.visitNotEligible("no visit \(visitId)")
            }
            if unit.state.hasLiveTicket(visitId: visitId) {
                throw ClinicError.visitHasLiveTicket("visit \(visitId) already has a live ticket")
            }
            guard QueueEngine.constants.reservableStatuses.contains(status) else {
                throw ClinicError.visitNotEligible("visit \(visitId) is \(status.rawValue)")
            }
            let ticketId = unit.newId("tkt")
            unit.state.tickets.append(
                TicketRecord(
                    id: ticketId, visitId: visitId, centreId: counter.centreId,
                    counterId: counterId, state: .reserved, reservedAt: unit.stamp))
            unit.state.updateVisit(visitId) {
                $0.status = .reserved
                $0.centreId = counter.centreId
            }
            return try unit.record(ticketId, "ticket.reserved")
        }
    }

    /// The patient arrived: assigns the number and joins the end of the queue.
    public mutating func activate(
        _ state: inout ClinicState, ticketId: String, method: String = "button"
    ) throws -> TicketRecord {
        let now = clock()
        try expire(&state, now)  // Commits on its own, so the release survives the throw below.
        return try transaction(&state, at: now) { unit in
            let row = try unit.state.loadTicket(ticketId)
            if QueueEngine.wasExpired(row) {
                throw ClinicError.ticketExpired("ticket \(ticketId) passed its check-in window")
            }
            guard row.state == .reserved else {
                throw ClinicError.invalidTransition("cannot activate a \(row.state.rawValue) ticket")
            }
            let status = unit.state.visitStatus(row.visitId)
            guard status == .reserved, let visitId = row.visitId else {
                throw ClinicError.visitNotEligible(
                    "visit \(row.visitId ?? "None") is \(status?.rawValue ?? "None")")
            }
            let number = unit.numbered(try unit.state.loadCounter(row.counterId))
            let priority = unit.priority(visitId: visitId, centreId: row.centreId)
            let stamp = unit.stamp
            unit.state.updateTicket(ticketId) {
                $0.state = .active
                $0.activatedAt = stamp
                $0.priority = priority
                $0.number = number.number
                $0.seq = number.seq
                $0.day = number.day
            }
            unit.state.updateVisit(visitId) {
                $0.status = .inTriage
                $0.arrivedAt = stamp
            }
            return try unit.record(
                ticketId, "ticket.activated", detail: ["method": .string(method)])
        }
    }

    /// True for a ticket the window released, false for one cancelled in time.
    private static func wasExpired(_ row: TicketRecord) -> Bool {
        guard row.state == .released, row.activatedAt == nil,
              let reservedAt = row.reservedAt, let releasedAt = row.releasedAt
        else { return false }
        let deadline = ClinicTime.storedMicroseconds(reservedAt) + reservationWindow
        return ClinicTime.storedMicroseconds(releasedAt) >= deadline
    }

    public mutating func issueActive(
        _ state: inout ClinicState, visitId: String, counterId: String
    ) throws -> TicketRecord {
        let now = clock()
        try expire(&state, now)
        return try transaction(&state, at: now) { unit in
            let counter = try unit.state.loadCounter(counterId)
            return try unit.joinQueue(visitId: visitId, counter: counter)
        }
    }

    /// A waiting ticket with no patient behind it, for the simulated load.
    public mutating func issueSimulated(_ state: inout ClinicState, counterId: String) throws
        -> TicketRecord
    {
        try transaction(&state, at: clock()) { unit in
            let counter = try unit.state.loadCounter(counterId)
            let number = unit.numbered(counter)
            let ticketId = unit.newId("tkt")
            unit.state.tickets.append(
                TicketRecord(
                    id: ticketId, visitId: nil, centreId: counter.centreId, counterId: counterId,
                    number: number.number, day: number.day, seq: number.seq, state: .active,
                    simulated: true, activatedAt: unit.stamp))
            return try unit.record(
                ticketId, "ticket.activated", detail: ["method": .string("simulated")])
        }
    }

    // At the counter

    /// Calls the next patient. Simulated tickets ahead of them are finished on the way, and
    /// with only simulated tickets left, one moves on and nobody is called.
    public mutating func callNext(_ state: inout ClinicState, counterId: String) throws -> CallResult {
        let now = clock()
        try expire(&state, now)
        return try transaction(&state, at: now) { unit in
            _ = try unit.state.loadCounter(counterId)
            let busy = unit.state.tickets.contains {
                $0.counterId == counterId && ($0.state == .called || $0.state == .serving)
            }
            if busy { throw ClinicError.counterBusy("counter \(counterId) already has a patient") }
            let queue = unit.state.activeTickets(at: counterId)
            let firstReal = queue.firstIndex { !$0.simulated }
            let ahead = firstReal.map { queue[..<$0] } ?? queue.prefix(1)
            var autoCompleted: [TicketRecord] = []
            for row in ahead {
                autoCompleted.append(try unit.finishSimulated(row.id))
            }
            var called: TicketRecord?
            if let firstReal {
                let ticket = queue[firstReal]
                let stamp = unit.stamp
                unit.state.updateTicket(ticket.id) {
                    $0.state = .called
                    $0.calledAt = stamp
                    $0.callCount = ticket.callCount + 1
                }
                called = try unit.record(ticket.id, "ticket.called")
            }
            return CallResult(called: called, autoCompleted: autoCompleted)
        }
    }

    /// Moves one simulated ticket on. Real tickets are never touched.
    public mutating func completeSimulated(_ state: inout ClinicState, counterId: String) throws
        -> TicketRecord?
    {
        try transaction(&state, at: clock()) { unit in
            _ = try unit.state.loadCounter(counterId)
            guard let first = unit.state.activeTickets(at: counterId).first(where: \.simulated)
            else { return nil }
            return try unit.finishSimulated(first.id)
        }
    }

    public mutating func serve(_ state: inout ClinicState, ticketId: String) throws -> TicketRecord {
        try transaction(&state, at: clock()) { unit in
            let row = try unit.state.loadTicket(ticketId)
            guard row.state == .called else {
                throw ClinicError.invalidTransition("cannot serve a \(row.state.rawValue) ticket")
            }
            return try unit.serve(ticketId)
        }
    }

    /// Back to active. After the third call the ticket goes to the back of the queue.
    public mutating func noShow(_ state: inout ClinicState, ticketId: String) throws -> TicketRecord {
        try transaction(&state, at: clock()) { unit in
            let row = try unit.state.loadTicket(ticketId)
            guard row.state == .called else {
                throw ClinicError.invalidTransition(
                    "cannot mark a \(row.state.rawValue) ticket as no-show")
            }
            let movedToBack = row.callCount >= QueueEngine.constants.noShowLimit
            if movedToBack {
                let counter = try unit.state.loadCounter(row.counterId)
                let seq = unit.nextSeq(centreId: row.centreId, prefix: counter.prefix).seq
                let stamp = unit.stamp
                unit.state.updateTicket(ticketId) {
                    $0.state = .active
                    $0.activatedAt = stamp
                    $0.seq = seq
                }
            } else {
                unit.state.updateTicket(ticketId) { $0.state = .active }
            }
            return try unit.record(
                ticketId, "ticket.no_show", detail: ["moved_to_back": .bool(movedToBack)])
        }
    }

    public mutating func complete(_ state: inout ClinicState, ticketId: String) throws -> TicketRecord {
        try transaction(&state, at: clock()) { unit in try unit.finish(ticketId) }
    }

    /// Finishes this stage and joins the end of the next counter's queue.
    public mutating func advance(
        _ state: inout ClinicState, ticketId: String, nextCounterId: String
    ) throws -> TicketRecord {
        let now = clock()
        try expire(&state, now)
        return try transaction(&state, at: now) { unit in
            let finished = try unit.finish(ticketId)
            let counter = try unit.state.loadCounter(nextCounterId)
            guard counter.centreId == finished.centreId else {
                throw ClinicError.invalidTransition("counter \(nextCounterId) is at another centre")
            }
            return try unit.joinQueue(visitId: finished.visitId, counter: counter)
        }
    }

    public mutating func finishVisit(_ state: inout ClinicState, ticketId: String) throws
        -> TicketRecord
    {
        try transaction(&state, at: clock()) { unit in
            let row = try unit.finish(ticketId)
            if let status = unit.state.visitStatus(row.visitId),
               QueueEngine.noTicketStatuses.contains(status) {
                // An emergency must stay an emergency.
                throw ClinicError.visitNotEligible(
                    "visit \(row.visitId ?? "None") is \(status.rawValue)")
            }
            let stamp = unit.stamp
            unit.state.updateVisit(row.visitId) {
                $0.status = .completed
                $0.completedAt = stamp
            }
            return row
        }
    }

    public mutating func release(_ state: inout ClinicState, ticketId: String, reason: String) throws
        -> TicketRecord
    {
        try transaction(&state, at: clock()) { unit in
            try unit.release(ticketId, reason: reason)
        }
    }

    /// Releases a live ticket and sends the visit to emergency, in one step.
    public mutating func escalate(_ state: inout ClinicState, ticketId: String, reason: String) throws
        -> TicketRecord
    {
        try transaction(&state, at: clock()) { unit in
            let row = try unit.release(ticketId, reason: reason)
            unit.state.updateVisit(row.visitId) { $0.status = .redirectedEmergency }
            return row
        }
    }

    /// Releases every reserved ticket past its check-in window.
    @discardableResult
    public mutating func expireDue(_ state: inout ClinicState) throws -> [TicketRecord] {
        try expire(&state, clock())
    }

    /// `_expire`. Expired when now >= reserved_at + the window. Stored stamps are fixed width
    /// UTC, so the string compare is a time compare, exactly at the cutoff included.
    @discardableResult
    private mutating func expire(_ state: inout ClinicState, _ now: Date) throws -> [TicketRecord] {
        let cutoffMicros = ClinicTime.microseconds(of: now) - QueueEngine.reservationWindow
        let cutoff = ClinicTime.iso(ClinicTime.date(microseconds: cutoffMicros))
        return try transaction(&state, at: now) { unit in
            let due = unit.state.tickets.filter {
                $0.state == .reserved && ($0.reservedAt ?? "") <= cutoff
            }
            var expired: [TicketRecord] = []
            for row in due {
                let stamp = unit.stamp
                unit.state.updateTicket(row.id) {
                    $0.state = .released
                    $0.releasedAt = stamp
                }
                let released = try unit.record(
                    row.id, "ticket.released", detail: ["reason": .string("expired")])
                // A visit that moved on, such as to emergency, must not reopen.
                unit.state.updateVisit(released.visitId) {
                    if $0.status == .reserved { $0.status = .expired }
                }
                expired.append(released)
            }
            return expired
        }
    }

    // Reading the queue

    /// Where this ticket stands now.
    public mutating func position(_ state: inout ClinicState, ticketId: String) throws
        -> TicketPosition
    {
        try expire(&state, clock())
        let row = try state.loadTicket(ticketId)
        let peopleAhead = state.peopleAhead(row)
        var estWaitMin: Int?
        if let peopleAhead {
            let counter = try state.loadCounter(row.counterId)
            estWaitMin = QueueEngine.waitMin(
                peopleAhead: peopleAhead, avgServiceSec: QueueEngine.avgServiceSec(state, counter))
        }
        var expiresAt: String?
        if row.state == .reserved, let reservedAt = row.reservedAt {
            let deadline = ClinicTime.storedMicroseconds(reservedAt) + QueueEngine.reservationWindow
            expiresAt = ClinicTime.iso(ClinicTime.date(microseconds: deadline))
        }
        return TicketPosition(
            ticketId: row.id, state: row.state, number: row.number, peopleAhead: peopleAhead,
            estWaitMin: estWaitMin, expiresAt: expiresAt)
    }

    /// `views.ticket_view`: the ticket as it stands now, as the API returns it. A reserved
    /// ticket has no number and no place.
    public mutating func ticketView(_ state: inout ClinicState, ticket: TicketRecord) throws -> Ticket {
        let position = try position(&state, ticketId: ticket.id)
        let counter = try state.loadCounter(ticket.counterId)
        return Ticket(
            id: ticket.id, visitId: ticket.visitId ?? "", number: position.number,
            state: position.state, centreId: ticket.centreId, counterId: ticket.counterId,
            counter: counter.label, counterAr: counter.labelAr,
            peopleAhead: position.peopleAhead, estWaitMin: position.estWaitMin,
            expiresAt: position.expiresAt)
    }

    /// The visit's reserved, active, called or serving ticket, if any. No lazy expiry here:
    /// `activate` must see a past-due ticket to answer 410.
    public func liveTicket(_ state: ClinicState, visitId: String) -> TicketRecord? {
        state.tickets.last { $0.visitId == visitId && $0.state.isLive }
    }

    public func liveTicketsOfPatient(_ state: ClinicState, patientId: String) -> [TicketRecord] {
        state.tickets.filter { ticket in
            guard ticket.state.isLive, let visitId = ticket.visitId else { return false }
            return state.visit(visitId)?.patientId == patientId
        }
    }

    /// The visit's most recent ticket, in any state.
    public func latestTicket(_ state: ClinicState, visitId: String) -> TicketRecord? {
        state.tickets.last { $0.visitId == visitId }
    }

    /// The counter's queue: called and serving first, then active in order.
    public mutating func queueSnapshot(_ state: inout ClinicState, counterId: String) throws
        -> [QueueRow]
    {
        try expire(&state, clock())
        let atCounter = state.tickets
            .filter { $0.counterId == counterId && ($0.state == .called || $0.state == .serving) }
            .enumerated()
            .sorted { ($0.element.calledAt ?? "", $0.offset) < ($1.element.calledAt ?? "", $1.offset) }
            .map(\.element)
        let waiting = state.activeTickets(at: counterId)
        func row(_ ticket: TicketRecord, _ position: Int?) -> QueueRow {
            QueueRow(
                ticketId: ticket.id, number: ticket.number, state: ticket.state,
                priority: ticket.priority, simulated: ticket.simulated, visitId: ticket.visitId,
                activatedAt: ticket.activatedAt, calledAt: ticket.calledAt,
                callCount: ticket.callCount, label: ticket.simulated ? "Simulated" : nil,
                position: position)
        }
        return atCounter.map { row($0, nil) } + waiting.enumerated().map { row($1, $0 + 1) }
    }

    public func avgServiceSec(_ state: ClinicState, counterId: String) throws -> Double {
        QueueEngine.avgServiceSec(state, try state.loadCounter(counterId))
    }

    /// What a newcomer to this counter would face.
    public func counterWait(_ state: ClinicState, counterId: String) throws -> QueueWait {
        QueueEngine.counterWait(state, try state.loadCounter(counterId))
    }

    /// Triage wait plus the shortest doctor wait for the service.
    public func centreWait(_ state: ClinicState, centreId: String, service: String) -> QueueWait {
        let triage = state.triageCounter(centreId: centreId)
            .map { QueueEngine.counterWait(state, $0) } ?? QueueWait(peopleAhead: 0, waitMin: 0)
        let doctors = state.counters.filter { counter in
            guard counter.centreId == centreId, counter.stage == .doctor,
                  let staffId = counter.staffId, let staff = state.staffMember(staffId),
                  let clinic = staff.clinic
            else { return false }
            return clinic == service
        }
        let doctorMin = doctors.map { QueueEngine.counterWait(state, $0).waitMin }.min() ?? 0
        return QueueWait(peopleAhead: triage.peopleAhead, waitMin: triage.waitMin + doctorMin)
    }

    public func triageCounter(_ state: ClinicState, centreId: String) throws -> String {
        guard let counter = state.triageCounter(centreId: centreId) else {
            throw ClinicError.invalidTransition("centre \(centreId) has no triage counter")
        }
        return counter.id
    }

    /// `_avg_service_sec`: the rolling mean of the last 20 spans, in microsecond differences.
    /// Spans under 30 seconds are demo clicks. With too few samples, the counter's own default.
    static func avgServiceSec(_ state: ClinicState, _ counter: CounterRecord) -> Double {
        let done = state.tickets.enumerated()
            .filter {
                let ticket = $0.element
                return ticket.counterId == counter.id && ticket.state == .done
                    && !ticket.simulated && ticket.calledAt != nil
            }
            .sorted {
                let (first, second) = ($0.element.doneAt ?? "", $1.element.doneAt ?? "")
                return first != second ? first > second : $0.offset > $1.offset
            }
            .prefix(constants.rollingWindow)
        let spans = done.compactMap { row -> Double? in
            guard let doneAt = row.element.doneAt, let calledAt = row.element.calledAt else {
                return nil
            }
            let micros =
                ClinicTime.storedMicroseconds(doneAt) - ClinicTime.storedMicroseconds(calledAt)
            return Double(micros) / 1_000_000
        }.filter { $0 >= Double(constants.minSampleSec) }
        guard spans.count >= constants.minRollingSamples else {
            return Double(counter.avgServiceSec)
        }
        return pythonSum(spans) / Double(spans.count)
    }

    /// `sum()` on floats since Python 3.12: Neumaier's compensated summation.
    private static func pythonSum(_ values: [Double]) -> Double {
        var total = 0.0
        var compensation = 0.0
        for value in values {
            let next = total + value
            if abs(total) >= abs(value) {
                compensation += (total - next) + value
            } else {
                compensation += (value - next) + total
            }
            total = next
        }
        return compensation != 0 && compensation.isFinite ? total + compensation : total
    }

    /// `_wait_min`.
    static func waitMin(peopleAhead: Int, avgServiceSec: Double) -> Int {
        Int((Double(peopleAhead) * avgServiceSec / 60).rounded(.up))
    }

    /// `_counter_wait`.
    static func counterWait(_ state: ClinicState, _ counter: CounterRecord) -> QueueWait {
        let ahead = state.calledCount(at: counter.id) + state.activeTickets(at: counter.id).count
        return QueueWait(
            peopleAhead: ahead,
            waitMin: waitMin(peopleAhead: ahead, avgServiceSec: avgServiceSec(state, counter)))
    }
}
