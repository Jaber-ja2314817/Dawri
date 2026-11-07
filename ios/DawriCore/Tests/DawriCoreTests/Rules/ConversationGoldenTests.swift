import Foundation
import Testing
@testable import DawriCore

private struct NextTurnCase: Decodable {
    let history: [RulesHistoryRow]
    let patient: Int
    let denied: [String]
    let lang: String
    let reply: String
    let slot: String?
    let intake: RulesIntakeRow?
    let language: String

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        history = try row.decode([RulesHistoryRow].self)
        patient = try row.decode(Int.self)
        denied = try row.decode([String].self)
        lang = try row.decode(String.self)
        reply = try row.decode(String.self)
        slot = try row.decode(String?.self)
        intake = try row.decode(RulesIntakeRow?.self)
        language = try row.decode(String.self)
    }
}

private struct EventRow: Decodable {
    let type: String
    let payload: JSONValue

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        type = try row.decode(String.self)
        payload = try row.decode(JSONValue.self)
    }
}

private struct ResultRow: Decodable {
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
    let events: [EventRow]
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
        events = try row.decode([EventRow].self)
        fired = try row.decode([String].self)
    }
}

private struct RunTurnCase: Decodable {
    let function: String
    let text: String
    let history: [RulesHistoryRow]
    let patient: Int
    let denied: [String]?
    let lang: String?
    let result: ResultRow?

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        function = try row.decode(String.self)
        text = try row.decode(String.self)
        history = try row.decode([RulesHistoryRow].self)
        patient = try row.decode(Int.self)
        denied = try row.decode([String]?.self)
        lang = try row.decode(String?.self)
        result = try row.decode(ResultRow?.self)
    }
}

extension Rules {
    @Suite("Rules: conversation goldens")
    struct ConversationGoldenTests {
        @Test func `next_turn golden`() throws {
            let golden = try Golden.load(.rules, "next_turn", as: NextTurnCase.self)
            let people = rulesPatients(in: golden)
            var differences = Differences("next_turn.json")
            let ran = golden.run { item in
                let messages = item.history.messages
                let input = "\(messages.map(\.content))"
                do {
                    let turn = try Scripted.nextTurn(
                        history: messages, patient: people[item.patient], denied: item.denied, lang: item.lang)
                    differences.check(input, "reply", item.reply, turn.reply)
                    differences.check(input, "slot", item.slot, turn.slot)
                    differences.check(input, "language", item.language, turn.language)
                    differences.check(input, item.intake, turn.intake)
                } catch {
                    differences.report(input: input, field: "threw", expected: item.reply, found: "\(error)")
                }
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        @Test func `run_turn golden`() throws {
            let golden = try Golden.load(.rules, "run_turn", as: RunTurnCase.self)
            let people = rulesPatients(in: golden)
            var differences = Differences("run_turn.json")
            let ran = golden.run { item in
                let messages = item.history.messages
                let input = "\(item.function): \(messages.map(\.content)) then \(item.text)"
                do {
                    let found: TurnResult?
                    if item.function == "run_turn" {
                        found = try Receptionist.runTurn(
                            text: item.text, history: messages, patient: people[item.patient],
                            denied: item.denied, lang: item.lang)
                    } else {
                        found = Receptionist.ruleEmergency(
                            text: item.text, history: messages, patient: people[item.patient],
                            denied: item.denied, lang: item.lang)
                    }
                    Self.compare(item.result, found, input: input, into: &differences)
                } catch {
                    differences.report(input: input, field: "threw", expected: "a turn", found: "\(error)")
                }
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        private static func compare(
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
            differences.check(input, "denied", expected.denied, found.denied)
            differences.check(input, "source", expected.source, found.source)
            differences.check(input, "emergency_category", expected.emergencyCategory, found.emergencyCategory)
            differences.check(input, "self_harm", expected.selfHarm, found.selfHarm)
            differences.check(input, "language", expected.language, found.language)
            differences.check(input, "slot", expected.slot, found.slot)
            differences.check(input, "fired", expected.fired, found.fired)
            differences.check(input, "event types", expected.events.map(\.type), found.events.map(\.type))
            for (want, got) in zip(expected.events, found.events)
            where !rulesSameJSON(want.payload, .object(got.payload)) {
                differences.report(
                    input: input, field: "event \(want.type)", expected: "\(want.payload)", found: "\(got.payload)")
            }
        }
    }
}
