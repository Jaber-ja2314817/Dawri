import Foundation
import Testing
@testable import DawriCore

private struct EventRow: Decodable, Sendable {
    let type: String
    let payload: JSONValue

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        type = try row.decode(String.self)
        payload = try row.decode(JSONValue.self)
    }
}

/// `result_columns`.
private struct ResultRow: Decodable, Sendable {
    let reply: String
    let done: Bool
    let emergency: Bool
    let intake: RulesIntakeRow?
    let refill: RefillMedicine?
    let denied: [String]
    let source: String
    let emergencyCategory: String?
    let selfHarm: Bool
    let language: String
    let slot: String?
    let fired: [String]

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        reply = try row.decode(String.self)
        done = try row.decode(Bool.self)
        emergency = try row.decode(Bool.self)
        intake = try row.decode(RulesIntakeRow?.self)
        refill = try row.decode(RefillMedicine?.self)
        denied = try row.decode([String].self)
        source = try row.decode(String.self)
        emergencyCategory = try row.decode(String?.self)
        selfHarm = try row.decode(Bool.self)
        language = try row.decode(String.self)
        slot = try row.decode(String?.self)
        fired = try row.decode([String].self)
    }
}

/// `last_turn_columns`.
private struct LastTurnRow: Decodable, Sendable {
    let turn: LastTurn

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        let reply = try row.decode(String.self)
        let done = try row.decode(Bool.self)
        let emergency = try row.decode(Bool.self)
        let intake = try row.decode(Intake?.self)
        let refill = try row.decode(RefillMedicine?.self)
        let denied = try row.decode([String].self)
        let source = try row.decode(String.self)
        let selfHarm = try row.decode(Bool.self)
        let category = try row.decode(String?.self)
        turn = LastTurn(
            reply: reply, done: done, emergency: emergency, intake: intake, refill: refill,
            denied: denied, aiSource: source, selfHarm: selfHarm, emergencyCategory: category)
    }
}

/// `turn_columns`.
private struct TurnRow: Decodable, Sendable {
    let action: String
    let text: String?
    let error: String?
    let result: ResultRow?
    let refillIntake: RulesIntakeRow?
    let status: String
    let service: String?
    let added: [RulesHistoryRow]
    let count: Int
    let denied: [String]
    let language: String?
    let lastTurn: LastTurnRow?
    let events: [EventRow]

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        action = try row.decode(String.self)
        text = try row.decode(String?.self)
        error = try row.decode(String?.self)
        if action == "continue_refill" {
            refillIntake = try row.decode(RulesIntakeRow?.self)
            result = nil
        } else {
            result = try row.decode(ResultRow?.self)
            refillIntake = nil
        }
        status = try row.decode(String.self)
        service = try row.decode(String?.self)
        added = try row.decode([RulesHistoryRow].self)
        count = try row.decode(Int.self)
        denied = try row.decode([String].self)
        language = try row.decode(String?.self)
        lastTurn = try row.decode(LastTurnRow?.self)
        events = try row.decode([EventRow].self)
    }
}

/// `initial.state`: the transcript column as a harvested test had it.
private struct InitialChat: Decodable, Sendable {
    let messages: [ChatMessage]
    let denied: [String]
    let language: String
    let lastTurn: LastTurn?

    enum CodingKeys: String, CodingKey {
        case messages, denied, language
        case lastTurn = "last_turn"
    }
}

private struct InitialRow: Decodable, Sendable {
    let status: VisitStatus
    let state: InitialChat?
}

private struct SessionCase: Decodable, Sendable {
    let family: Int
    let patient: String
    let on: String
    let initial: InitialRow?
    let turns: [TurnRow]

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        family = try row.decode(Int.self)
        patient = try row.decode(String.self)
        on = try row.decode(String.self)
        initial = try row.decode(InitialRow?.self)
        turns = try row.decode([TurnRow].self)
    }
}

/// What one step left behind, gathered inside the actor.
private struct Observed: Sendable {
    var error: String?
    var result: TurnResult?
    var refillIntake: IntakeRecord?
    var status: VisitStatus?
    var service: Service?
    var added: [ChatMessage] = []
    var count = 0
    var denied: [String] = []
    var language: String?
    var lastTurn: LastTurn?
    var events: [EventRecord] = []
}

extension Local {
    @Suite("Local: session replay")
    struct SessionReplayTests {
        private static let visitId = "V_replay000001"

        private static func step(
            _ turn: TurnRow, on day: String, _ state: inout LocalState, now: Date
        ) -> Observed {
            let (messages, events) = (state.chats[visitId]?.messages.count ?? 0, state.clinic.events.count)
            var seen = Observed()
            do {
                switch turn.action {
                case "say":
                    seen.result = try state.handleMessage(
                        visitId: visitId, text: turn.text ?? "", on: .day(day), now: now)
                case "past_arrival":
                    seen.result = try state.redFlagPastArrival(
                        visitId: visitId, message: turn.text ?? "", on: .day(day), now: now)
                case "continue_refill":
                    seen.refillIntake = try state.continueAfterRefill(
                        visitId: visitId, on: .day(day), now: now)
                case "set_status":
                    let status = VisitStatus(rawValue: turn.text ?? "")
                    state.clinic.updateVisit(visitId) { $0.status = status ?? .intake }
                default:
                    Issue.record("No step \(turn.action)")
                }
            } catch let error as ClinicError {
                seen.error = error.code
            } catch {
                Issue.record("\(turn.action) threw \(error)")
            }
            let chat = state.chats[visitId]
            seen.status = state.clinic.visit(visitId)?.status
            seen.service = state.clinic.visit(visitId)?.service
            seen.added = Array((chat?.messages ?? []).dropFirst(messages))
            seen.count = chat?.messages.count ?? 0
            seen.denied = chat?.denied ?? []
            seen.language = chat?.language
            seen.lastTurn = chat?.lastTurn
            seen.events = Array(state.clinic.events.dropFirst(events))
            return seen
        }

        private static func compare(
            _ turn: TurnRow, _ seen: Observed, input: String, into differences: inout Differences
        ) {
            differences.check(input, "error", turn.error, seen.error)
            differences.check(input, "status", turn.status, seen.status?.rawValue)
            differences.check(input, "service", turn.service, seen.service?.rawValue)
            differences.check(input, turn.refillIntake, seen.refillIntake)
            compareResult(turn.result, seen.result, input: input, into: &differences)

            differences.check(input, "added", turn.added.count, seen.added.count)
            for (want, got) in zip(turn.added.messages, seen.added) {
                differences.check(input, "added.role", want.role.rawValue, got.role.rawValue)
                differences.check(input, "added.content", want.content, got.content)
                differences.check(input, "added.slot", want.slot, got.slot)
            }
            differences.check(input, "count", turn.count, seen.count)
            differences.check(input, "denied", turn.denied, seen.denied)
            differences.check(input, "language", turn.language, seen.language)
            compareLastTurn(turn.lastTurn?.turn, seen.lastTurn, input: input, into: &differences)

            differences.check(input, "event types", turn.events.map(\.type), seen.events.map(\.type))
            for (want, got) in zip(turn.events, seen.events) where !rulesSameJSON(want.payload, got.payload) {
                differences.report(
                    input: input, field: "event \(want.type)", expected: "\(want.payload)",
                    found: "\(got.payload)")
            }
        }

        private static func compareResult(
            _ expected: ResultRow?, _ found: TurnResult?, input: String, into differences: inout Differences
        ) {
            guard let expected, let found else {
                differences.check(input, "result", expected == nil, found == nil)
                return
            }
            differences.check(input, "reply", expected.reply, found.reply)
            differences.check(input, "done", expected.done, found.done)
            differences.check(input, "emergency", expected.emergency, found.emergency)
            differences.check(input, expected.intake, found.intake)
            differences.check(input, "refill", expected.refill?.medicine, found.refill?.medicine)
            differences.check(input, "result.denied", expected.denied, found.denied)
            differences.check(input, "source", expected.source, found.source)
            differences.check(input, "emergency_category", expected.emergencyCategory, found.emergencyCategory)
            differences.check(input, "self_harm", expected.selfHarm, found.selfHarm)
            differences.check(input, "result.language", expected.language, found.language)
            differences.check(input, "slot", expected.slot, found.slot)
            differences.check(input, "fired", expected.fired, found.fired)
        }

        private static func compareLastTurn(
            _ expected: LastTurn?, _ found: LastTurn?, input: String, into differences: inout Differences
        ) {
            guard let expected, let found else {
                differences.check(input, "last_turn", expected == nil, found == nil)
                return
            }
            differences.check(input, "last_turn.reply", expected.reply, found.reply)
            differences.check(input, "last_turn.done", expected.done, found.done)
            differences.check(input, "last_turn.emergency", expected.emergency, found.emergency)
            differences.check(input, "last_turn.intake", expected.intake, found.intake)
            differences.check(input, "last_turn.refill", expected.refill?.medicine, found.refill?.medicine)
            differences.check(input, "last_turn.denied", expected.denied, found.denied)
            differences.check(input, "last_turn.ai_source", expected.aiSource, found.aiSource)
            differences.check(input, "last_turn.self_harm", expected.selfHarm, found.selfHarm)
            differences.check(input, "last_turn.category", expected.emergencyCategory, found.emergencyCategory)
        }

        private static func replay(_ item: SessionCase, on base: LocalState, now: Date) async -> Differences {
            var state = base
            state.clinic.visits.append(
                VisitRecord(
                    id: visitId, patientId: item.patient, status: item.initial?.status ?? .intake,
                    createdAt: journeyStart))
            if let chat = item.initial?.state {
                state.chats[visitId] = ChatRecord(
                    messages: chat.messages, denied: chat.denied, language: chat.language,
                    lastTurn: chat.lastTurn)
            }
            let service = LocalClinicService(
                clock: { now }, store: FixedClinicStore(state: state), demoClinic: false)
            var differences = Differences("sessions.json")
            for (index, turn) in item.turns.enumerated() {
                let seen = await service.testing { state, _ in
                    step(turn, on: item.on, &state, now: now)
                }
                let input = "\(item.family) \(item.patient) turn \(index) \(turn.action): \(turn.text ?? "")"
                compare(turn, seen, input: input, into: &differences)
            }
            differences.finish(ran: item.turns.count)
            return differences
        }

        @Test func `every recorded turn of every conversation matches`() async throws {
            let golden = try Golden.load(.journeys, "sessions", as: SessionCase.self)
            let clock = try TestClock(journeyStart)
            var engine = makeEngine(clock)
            let base = try LocalState.fresh(engine: &engine)
            let now = clock.now
            let lanes = max(ProcessInfo.processInfo.activeProcessorCount - 2, 2)
            let size = golden.cases.count / lanes + 1
            let groups = stride(from: 0, to: golden.cases.count, by: size).map {
                Array(golden.cases[$0..<min($0 + size, golden.cases.count)])
            }
            let ran = await withTaskGroup(of: Int.self) { group in
                for items in groups {
                    group.addTask {
                        var ran = 0
                        for item in items {
                            _ = await Self.replay(item, on: base, now: now)
                            ran += 1
                        }
                        return ran
                    }
                }
                return await group.reduce(0, +)
            }
            #expect(ran == golden.count)
            #expect(try Golden.manifest(.journeys).files["sessions.json"]?.count == ran)
        }
    }
}
