import Foundation

/// `_Unit`: one transaction. It works on a draft of the state, so a throw rolls everything back
/// by dropping the draft, and it lines up the messages to publish after the commit.
struct QueueUnit {
    var state: ClinicState
    let now: Date
    let stamp: String
    let newId: @Sendable (String) -> String
    var messages: [QueueMessage] = []
    /// Counter ids in first-touched order, each with the tickets whose own event went out.
    private var subjects: [(counterId: String, tickets: Set<String>)] = []

    init(state: ClinicState, now: Date, newId: @escaping @Sendable (String) -> String) {
        self.state = state
        self.now = now
        self.stamp = ClinicTime.iso(now)
        self.newId = newId
    }

    /// `_record`: writes the event row and lines up the messages for this transition.
    @discardableResult
    mutating func record(
        _ ticketId: String, _ eventType: String, detail: [String: JSONValue] = [:]
    ) throws -> TicketRecord {
        let row = try state.loadTicket(ticketId)
        var payload: [String: JSONValue] = [
            "ticket_id": .string(row.id),
            "number": .optional(row.number),
            "counter_id": .string(row.counterId),
        ]
        payload.merge(detail) { _, new in new }
        state.appendEvent(
            visitId: row.visitId, type: eventType, payload: .object(payload), at: stamp)

        let label = try state.loadCounter(row.counterId).label
        var display: [String: JSONValue] = [
            "type": .string(eventType),
            "ticket": .optional(row.number),
            "counter": .string(label),
            "people_ahead": .optional(state.peopleAhead(row)),
        ]
        var message = display
        message["visit_id"] = .optional(row.visitId)
        messages.append(QueueMessage(channel: .counter(row.counterId), event: .object(message)))
        if let visitId = row.visitId {
            messages.append(QueueMessage(channel: .visit(visitId), event: .object(message)))
        }
        // The TV in the waiting room gets numbers only, never a patient link.
        display["visit_id"] = nil
        messages.append(QueueMessage(channel: .display(row.centreId), event: .object(display)))

        if let index = subjects.firstIndex(where: { $0.counterId == row.counterId }) {
            subjects[index].tickets.insert(row.id)
        } else {
            subjects.append((row.counterId, [row.id]))
        }
        return row
    }

    /// `_queue_changed`: tells every other waiting patient on the touched counters to refetch.
    /// SQLite reads these from ix_ticket_queue, so active come before called, each in queue order.
    mutating func announceQueueChange() throws {
        for (counterId, tickets) in subjects {
            let label = try state.loadCounter(counterId).label
            let message: JSONValue = .object([
                "type": .string("queue.changed"), "counter": .string(label),
            ])
            let waiting = state.tickets.filter { $0.counterId == counterId && !$0.simulated }
            let active = state.queueOrdered(waiting.filter { $0.state == .active })
            let called = state.queueOrdered(waiting.filter { $0.state == .called })
            for row in active + called where !tickets.contains(row.id) {
                guard let visitId = row.visitId else { continue }
                messages.append(QueueMessage(channel: .visit(visitId), event: message))
            }
        }
    }

    /// `_next_seq`: the sequence belongs to the centre, the prefix and the Doha day.
    mutating func nextSeq(centreId: String, prefix: String) -> (seq: Int, day: String) {
        let day = ClinicTime.dohaDay(now)
        let found = state.sequences.firstIndex {
            $0.centreId == centreId && $0.prefix == prefix && $0.day == day
        }
        if let found {
            state.sequences[found].lastValue += 1
            return (state.sequences[found].lastValue, day)
        }
        state.sequences.append(
            NumberSequenceRecord(centreId: centreId, prefix: prefix, day: day, lastValue: 1))
        return (1, day)
    }

    /// `_numbered`: prefix-seq with at least three digits.
    mutating func numbered(_ counter: CounterRecord) -> (number: String, seq: Int, day: String) {
        let (seq, day) = nextSeq(centreId: counter.centreId, prefix: counter.prefix)
        let digits = String(seq)
        let padded = String(repeating: "0", count: max(3 - digits.count, 0)) + digits
        return ("\(counter.prefix)-\(padded)", seq, day)
    }

    /// `_priority`: the centre's age rule on the visit's patient, the dependent and not the
    /// guardian.
    func priority(visitId: String, centreId: String) -> Int {
        guard let visit = state.visit(visitId), let patient = state.patient(visit.patientId),
              let centre = state.centre(centreId)
        else { preconditionFailure("A ticket needs a visit, a patient and a centre") }
        return ClinicTime.ageOn(dob: patient.dob, at: now) >= centre.priorityAgeMin ? 1 : 0
    }

    /// `_join_queue`. Not every visit has one, because a simulated ticket can be advanced.
    mutating func joinQueue(visitId: String?, counter: CounterRecord) throws -> TicketRecord {
        let named = visitId ?? "None"
        guard let visitId, let status = state.visitStatus(visitId) else {
            throw ClinicError.visitNotEligible("no visit \(named)")
        }
        if state.hasLiveTicket(visitId: visitId) {
            throw ClinicError.visitHasLiveTicket("visit \(visitId) already has a live ticket")
        }
        if QueueEngine.noTicketStatuses.contains(status) {
            throw ClinicError.visitNotEligible("visit \(visitId) is \(status.rawValue)")
        }
        let ticketId = newId("tkt")
        let number = numbered(counter)
        let priority = priority(visitId: visitId, centreId: counter.centreId)
        state.tickets.append(
            TicketRecord(
                id: ticketId, visitId: visitId, centreId: counter.centreId, counterId: counter.id,
                number: number.number, day: number.day, seq: number.seq, priority: priority,
                state: .active, activatedAt: stamp))
        state.updateVisit(visitId) { [stamp] visit in
            visit.status = counter.stage.visitStatus
            visit.centreId = counter.centreId
            visit.arrivedAt = visit.arrivedAt ?? stamp
        }
        return try record(ticketId, "ticket.activated", detail: ["method": .string("direct")])
    }

    /// `_finish_simulated`.
    mutating func finishSimulated(_ ticketId: String) throws -> TicketRecord {
        state.updateTicket(ticketId) { [stamp] in
            $0.state = .done
            $0.doneAt = stamp
        }
        return try record(
            ticketId, "ticket.simulated_done",
            detail: ["note": .string(ClinicData.bundled.constants.simulatedNote)])
    }

    /// `_serve`.
    @discardableResult
    mutating func serve(_ ticketId: String) throws -> TicketRecord {
        state.updateTicket(ticketId) { $0.state = .serving }
        return try record(ticketId, "ticket.serving")
    }

    /// `_finish`.
    mutating func finish(_ ticketId: String) throws -> TicketRecord {
        let row = try state.loadTicket(ticketId)
        guard row.state == .called || row.state == .serving else {
            throw ClinicError.invalidTransition("cannot complete a \(row.state.rawValue) ticket")
        }
        if row.state == .called { try serve(ticketId) }
        state.updateTicket(ticketId) { [stamp] in
            $0.state = .done
            $0.doneAt = stamp
        }
        return try record(ticketId, "ticket.done")
    }

    /// `_release`.
    mutating func release(_ ticketId: String, reason: String) throws -> TicketRecord {
        let row = try state.loadTicket(ticketId)
        guard row.state.isLive else {
            throw ClinicError.invalidTransition("cannot release a \(row.state.rawValue) ticket")
        }
        state.updateTicket(ticketId) { [stamp] in
            $0.state = .released
            $0.releasedAt = stamp
        }
        return try record(ticketId, "ticket.released", detail: ["reason": .string(reason)])
    }
}

extension JSONValue {
    static func optional(_ value: String?) -> JSONValue {
        value.map(JSONValue.string) ?? .null
    }

    static func optional(_ value: Int?) -> JSONValue {
        value.map { .number(Double($0)) } ?? .null
    }
}
