import Foundation
import Testing
@testable import DawriCore

/// A row of queue_traces.json: [family, name, setup, ops, final].
struct TraceRow: Decodable {
    struct Setup: Decodable {
        let start: String
        let queue: String
        let watch: [String]
    }

    struct Op: Decodable {
        let op: String
        let args: [JSONValue]
        let kwargs: [String: JSONValue]
        let result: JSONValue
        let error: String?
        let messages: JSONValue
        let snapshots: JSONValue
        let snapshotMessages: JSONValue

        private struct Arguments: Decodable {
            let args: [JSONValue]
            let kwargs: [String: JSONValue]
        }

        init(from decoder: any Decoder) throws {
            var row = try decoder.unkeyedContainer()
            op = try row.decode(String.self)
            let arguments = try row.decode(Arguments.self)
            args = arguments.args
            kwargs = arguments.kwargs
            result = try row.decode(JSONValue.self)
            error = try row.decode(String?.self)
            messages = try row.decode(JSONValue.self)
            snapshots = try row.decode(JSONValue.self)
            snapshotMessages = try row.decode(JSONValue.self)
        }
    }

    let family: String
    let name: String
    let setup: Setup
    let ops: [Op]
    let final: JSONValue

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        family = try row.decode(String.self)
        name = try row.decode(String.self)
        setup = try row.decode(Setup.self)
        ops = try row.decode([Op].self)
        final = try row.decode(JSONValue.self)
    }
}

/// `Trace` in ios/Tools/export/clinic.py, on the Swift engine.
struct TraceReplay {
    /// What one step did, each part aliased in the order `Trace.op` aliases it.
    struct Observed {
        var result: JSONValue = .null
        var error: String?
        var messages: JSONValue = .array([])
        var snapshots: JSONValue = .object([:])
        var snapshotMessages: JSONValue = .array([])
    }

    let clock: TestClock
    let ids = CountingIds()
    let watch: [String]
    var engine: QueueEngine
    var state = ClinicState()
    var aliases = IdAliases()
    var patientSerial = 0

    init(_ setup: TraceRow.Setup) throws {
        clock = try TestClock(setup.start)
        watch = setup.watch
        engine = makeEngine(clock, ids)
        if setup.queue != "empty" {
            try SimulatedLoad.seedQueueState(&engine, &state, simulateLoad: setup.queue == "load")
        }
        _ = engine.takeMessages()
    }

    private mutating func arguments(_ op: TraceRow.Op) -> [String] {
        var mapped: [String] = []
        for argument in op.args {
            mapped.append(aliases.resolve(argument.string ?? ""))
        }
        return mapped
    }

    private mutating func perform(_ op: TraceRow.Op, _ args: [String]) throws -> JSONValue {
        switch op.op {
        case "new_visit":
            let id = ids.next("V")
            let status = args.count > 1 ? VisitStatus(rawValue: args[1]) ?? .intake : .intake
            state.visits.append(
                VisitRecord(
                    id: id, patientId: args[0], status: status,
                    createdAt: args.count > 2 ? args[2] : "2026-11-06T06:00:00.000000+00:00"))
            return .string(id)
        case "new_patient":
            patientSerial += 1
            let id = "PX\(patientSerial)"
            state.patients.append(
                PatientRecord(
                    id: id, qidDemo: "TEST-\(patientSerial)", fullNameEn: "Test", fullNameAr: "Test",
                    dob: args[0], sex: "F", preferredLang: "ar", registeredCentreId: "C-WAKRA",
                    allergies: [], chronic: [], activeMeds: []))
            return .string(id)
        case "set_visit_status":
            let status = try #require(VisitStatus(rawValue: args[1]))
            state.updateVisit(args[0]) { $0.status = status }
            return .null
        case "tick":
            clock.advance(seconds: try #require(op.kwargs["seconds"]?.double))
            return .null
        case "add_event":
            state.appendEvent(
                visitId: args[0], type: args[1], payload: .object([:]),
                at: ClinicTime.iso(clock.now))
            return .null
        case "leave_the_queue":
            try VisitFlow.leaveTheQueue(&engine, &state, patientId: args[0])
            return .null
        case "emergency_today":
            return .optional(
                VisitFlow.emergencyToday(
                    state, patientId: args[0], now: clock.now,
                    otherThan: args.count > 1 ? args[1] : nil))
        case "complete_consult":
            return shape(try completeConsult(op, args))
        case "dispense":
            let ticket = try #require(engine.liveTicket(state, visitId: args[0]))
            return shape(
                try VisitFlow.dispense(
                    &engine, &state, visitId: args[0], ticket: ticket, actor: args[1]))
        case "for_visit":
            let lines = MedicineLines.forVisit(state, visitId: args[0], lang: args[1])
            return .array(
                lines.map {
                    .object([
                        "drug": .string($0.drug), "name": .string($0.name),
                        "line": .string($0.line),
                    ])
                })
        case "live_tickets_of_patient":
            return .array(engine.liveTicketsOfPatient(state, patientId: args[0]).map(shape))
        case "issue_ticket":
            return shape(try engine.issueTicket(&state, visitId: args[0], counterId: args[1]))
        case "activate":
            return shape(try engine.activate(&state, ticketId: args[0], method: args[1]))
        case "issue_active":
            return shape(try engine.issueActive(&state, visitId: args[0], counterId: args[1]))
        case "issue_simulated":
            return shape(try engine.issueSimulated(&state, counterId: args[0]))
        case "call_next":
            return shape(try engine.callNext(&state, counterId: args[0]))
        case "complete_simulated":
            return try engine.completeSimulated(&state, counterId: args[0]).map(shape) ?? .null
        case "serve":
            return shape(try engine.serve(&state, ticketId: args[0]))
        case "no_show":
            return shape(try engine.noShow(&state, ticketId: args[0]))
        case "complete":
            return shape(try engine.complete(&state, ticketId: args[0]))
        case "advance":
            return shape(try engine.advance(&state, ticketId: args[0], nextCounterId: args[1]))
        case "finish_visit":
            return shape(try engine.finishVisit(&state, ticketId: args[0]))
        case "release":
            return shape(try engine.release(&state, ticketId: args[0], reason: args[1]))
        case "escalate":
            return shape(try engine.escalate(&state, ticketId: args[0], reason: args[1]))
        case "expire_due":
            return .array(try engine.expireDue(&state).map(shape))
        case "position":
            return shape(try engine.position(&state, ticketId: args[0]))
        case "live_ticket":
            return engine.liveTicket(state, visitId: args[0]).map(shape) ?? .null
        case "latest_ticket":
            return engine.latestTicket(state, visitId: args[0]).map(shape) ?? .null
        case "queue_snapshot":
            return .array(try engine.queueSnapshot(&state, counterId: args[0]).map(shapeObject))
        case "avg_service_sec":
            return .number(try engine.avgServiceSec(state, counterId: args[0]))
        case "counter_wait":
            return shape(try engine.counterWait(state, counterId: args[0]))
        case "centre_wait":
            return shape(engine.centreWait(state, centreId: args[0], service: args[1]))
        case "triage_counter":
            return .string(try engine.triageCounter(state, centreId: args[0]))
        default:
            Issue.record("No step for \(op.op)")
            return .null
        }
    }

    private mutating func completeConsult(_ op: TraceRow.Op, _ args: [String]) throws -> TicketRecord {
        let visit = try #require(state.visit(args[0]))
        let patient = try #require(state.patient(visit.patientId))
        let requested = args[1].split(separator: ",").map { PrescriptionRequest(drugId: String($0)) }
        let items = try VisitFlow.resolveItems(state, items: requested)
        let overrides = op.kwargs["overrides"] == .bool(true)
            ? VisitFlow.allergyConflicts(allergies: patient.allergies, items: items) : []
        let ticket = try #require(engine.liveTicket(state, visitId: visit.id))
        return try VisitFlow.completeConsult(
            &engine, &state, visitId: visit.id, ticket: ticket, items: items, actor: args[2],
            overrides: overrides)
    }

    /// `Trace._final`: what the database holds when the trace ends.
    mutating func finalState() -> JSONValue {
        aliases.apply(
            .object([
                "visits": .array(
                    state.visits.map {
                        .array([
                            .string($0.id), .string($0.patientId), .optional($0.centreId),
                            .string($0.status.rawValue), .optional($0.arrivedAt),
                            .optional($0.completedAt), .optional($0.bookedBy),
                        ])
                    }),
                "tickets": .array(
                    state.tickets.map { .array([.string($0.id), .optional($0.day)]) }),
                "sequences": .array(
                    state.sequences.map {
                        .array([
                            .string($0.centreId), .string($0.prefix), .string($0.day),
                            .number($0.lastValue),
                        ])
                    }),
                "events": .array(
                    state.events.map {
                        .array([.optional($0.visitId), .string($0.type), $0.payload, .string($0.at)])
                    }),
            ]))
    }

    mutating func run(_ op: TraceRow.Op) throws -> Observed {
        var observed = Observed()
        let args = arguments(op)
        do {
            observed.result = aliases.apply(try perform(op, args))
        } catch let error as ClinicError {
            observed.error = error.code
            #expect(error.status == Self.statuses[error.code], "\(error.code)")
        }
        observed.messages = aliases.apply(shape(engine.takeMessages()))
        var snapshots: [String: JSONValue] = [:]
        for counter in watch {
            let rows = try engine.queueSnapshot(&state, counterId: counter)
            snapshots[counter] = .array(rows.map(shapeRow))
        }
        observed.snapshots = aliases.apply(.object(snapshots))
        observed.snapshotMessages = aliases.apply(shape(engine.takeMessages()))
        return observed
    }

    /// `_QUEUE_ERROR_STATUS` in backend/main.py.
    private static let statuses = [
        "ticket_not_found": 404, "ticket_expired": 410, "invalid_transition": 409,
        "visit_not_eligible": 409, "visit_has_live_ticket": 409, "counter_busy": 409,
    ]
}

/// The results under their Python field names.
private func shape(_ ticket: TicketRecord) -> JSONValue {
    .object([
        "id": .string(ticket.id), "visit_id": .optional(ticket.visitId),
        "counter_id": .string(ticket.counterId), "centre_id": .string(ticket.centreId),
        "number": .optional(ticket.number), "seq": .optional(ticket.seq),
        "priority": .number(ticket.priority), "state": .string(ticket.state.rawValue),
        "simulated": .bool(ticket.simulated), "call_count": .number(ticket.callCount),
        "reserved_at": .optional(ticket.reservedAt), "activated_at": .optional(ticket.activatedAt),
        "called_at": .optional(ticket.calledAt), "done_at": .optional(ticket.doneAt),
        "released_at": .optional(ticket.releasedAt),
    ])
}

private func shape(_ result: CallResult) -> JSONValue {
    .object([
        "called": result.called.map(shape) ?? .null,
        "auto_completed": .array(result.autoCompleted.map(shape)),
    ])
}

private func shape(_ position: TicketPosition) -> JSONValue {
    .object([
        "ticket_id": .string(position.ticketId), "state": .string(position.state.rawValue),
        "number": .optional(position.number), "people_ahead": .optional(position.peopleAhead),
        "est_wait_min": .optional(position.estWaitMin), "expires_at": .optional(position.expiresAt),
    ])
}

private func shape(_ wait: QueueWait) -> JSONValue {
    .object(["people_ahead": .number(wait.peopleAhead), "wait_min": .number(wait.waitMin)])
}

private func shape(_ messages: [QueueMessage]) -> JSONValue {
    .array(messages.map { .array([.string($0.channel.name), $0.event]) })
}

private func snapshotValues(_ row: QueueRow) -> [(String, JSONValue)] {
    [
        ("ticket_id", .string(row.ticketId)), ("number", .optional(row.number)),
        ("state", .string(row.state.rawValue)), ("priority", .number(row.priority)),
        ("simulated", .bool(row.simulated)), ("visit_id", .optional(row.visitId)),
        ("activated_at", .optional(row.activatedAt)), ("called_at", .optional(row.calledAt)),
        ("call_count", .number(row.callCount)), ("label", .optional(row.label)),
        ("position", .optional(row.position)),
    ]
}

private func shapeRow(_ row: QueueRow) -> JSONValue {
    .array(snapshotValues(row).map(\.1))
}

private func shapeObject(_ row: QueueRow) -> JSONValue {
    .object(Dictionary(uniqueKeysWithValues: snapshotValues(row)))
}

@Suite("Clinic queue traces")
struct ClinicQueueTraceTests {
    private func compare(
        _ part: String, _ found: JSONValue, _ expected: JSONValue, in trace: TraceRow, at index: Int
    ) -> Bool {
        if sameJSON(found, expected) { return true }
        Issue.record(
            """
            \(trace.family)/\(trace.name) op \(index) \(trace.ops[index].op) \(part)
            found    \(text(found))
            expected \(text(expected))
            """)
        return false
    }

    @Test func `the trace columns are the ones this replay assumes`() throws {
        let golden = try Golden.load(.clinic, "queue_traces", as: TraceRow.self)
        #expect(golden.header["op_columns"]?.array?.compactMap(\.string) == [
            "op", "args", "result", "error", "messages", "snapshots", "snapshot_messages",
        ])
        #expect(golden.header["snapshot_columns"]?.array?.compactMap(\.string) == [
            "ticket_id", "number", "state", "priority", "simulated", "visit_id", "activated_at",
            "called_at", "call_count", "label", "position",
        ])
        #expect(golden.header["visit_columns"]?.array?.compactMap(\.string) == [
            "id", "patient_id", "centre_id", "status", "arrived_at", "completed_at", "booked_by",
        ])
    }

    /// Every result, refusal, message and snapshot after every step, with the state pushed
    /// through JSON halfway, so a saved state carries on as the one in memory would.
    @Test func `every queue trace replays exactly`() throws {
        let golden = try Golden.load(.clinic, "queue_traces", as: TraceRow.self)
        var steps = 0
        let ran = try golden.run { trace in
            var replay = try TraceReplay(trace.setup)
            var diverged = false
            for (index, op) in trace.ops.enumerated() {
                if index == trace.ops.count / 2 {
                    let saved = try JSONEncoder().encode(replay.state)
                    let restored = try JSONDecoder().decode(ClinicState.self, from: saved)
                    #expect(restored == replay.state, "\(trace.name)")
                    replay.state = restored
                }
                let observed = try replay.run(op)
                steps += 1
                let same = [
                    compare("result", observed.result, op.result, in: trace, at: index),
                    compare(
                        "error", .optional(observed.error), .optional(op.error), in: trace,
                        at: index),
                    compare("messages", observed.messages, op.messages, in: trace, at: index),
                    compare("snapshots", observed.snapshots, op.snapshots, in: trace, at: index),
                    compare(
                        "snapshot messages", observed.snapshotMessages, op.snapshotMessages,
                        in: trace, at: index),
                ]
                if same.contains(false) {
                    diverged = true
                    break
                }
            }
            if !diverged {
                _ = compare(
                    "final state", replay.finalState(), trace.final, in: trace,
                    at: trace.ops.count - 1)
            }
        }
        #expect(ran == golden.count)
        #expect(steps == golden.cases.reduce(0) { $0 + $1.ops.count })
    }

    @Test func `the traces cover every family and every refusal`() throws {
        let golden = try Golden.load(.clinic, "queue_traces", as: TraceRow.self)
        #expect(Set(golden.cases.map(\.family)) == [
            "numbering", "midnight", "priority", "simulated", "expiry", "no_show", "rolling",
            "flow", "transition", "lazy_expiry", "visit_flow", "random",
        ])
        let errors = Set(golden.cases.flatMap { $0.ops.compactMap(\.error) })
        #expect(errors == [
            "ticket_not_found", "ticket_expired", "invalid_transition", "visit_not_eligible",
            "visit_has_live_ticket", "counter_busy",
        ])
    }
}
