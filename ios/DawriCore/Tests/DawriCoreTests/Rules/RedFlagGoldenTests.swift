import Foundation
import Testing
@testable import DawriCore

private struct SingleCase: Decodable {
    let text: String
    let hits: [Int]
    let denied: [Int]
    let categories: [Int]
    let emergency: Bool
    let selfHarm: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        _ = try row.decode(Int.self)
        text = try row.decode(String.self)
        hits = try row.decode([Int].self)
        denied = try row.decode([Int].self)
        categories = try row.decode([Int].self)
        emergency = try row.decode(Int.self) == 1
        selfHarm = try row.decode(Int.self) == 1
    }
}

private struct ConversationCase: Decodable {
    let history: [RulesHistoryRow]
    let text: String
    let hits: [Int]
    let denied: [Int]
    let fired: [String]
    let categories: [Int]
    let emergency: Bool
    let selfHarm: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        history = try row.decode([RulesHistoryRow].self)
        text = try row.decode(String.self)
        hits = try row.decode([Int].self)
        denied = try row.decode([Int].self)
        fired = try row.decode([String].self)
        categories = try row.decode([Int].self)
        emergency = try row.decode(Int.self) == 1
        selfHarm = try row.decode(Int.self) == 1
    }
}

/// The `hits` and `categories` tables of a golden's header.
private struct HitTable {
    let hits: [[String]]
    let categories: [String]

    init<Case>(_ golden: GoldenSet<Case>) {
        if case .array(let rows)? = golden.header["hits"] {
            hits = rows.map(rulesStrings)
        } else {
            hits = []
        }
        categories = rulesStrings(golden.header["categories"])
    }

    func text(_ hit: RedFlagHit) -> String { [hit.category, hit.cue, hit.labelEn, hit.labelAr].joined(separator: "|") }
    func text(_ index: Int) -> String { hits[index].joined(separator: "|") }
}

extension Rules {
    @Suite("Rules: red flag goldens")
    struct RedFlagGoldenTests {
        private static func compare(
            _ result: RedFlagResult, table: HitTable, input: String, hits: [Int], denied: [Int],
            categories: [Int], emergency: Bool, selfHarm: Bool, into differences: inout Differences
        ) {
            differences.check(input, "hits", hits.map(table.text), result.hits.map(table.text))
            differences.check(input, "denied", denied.map(table.text), result.denied.map(table.text))
            differences.check(input, "categories", categories.map { table.categories[$0] }, result.categories)
            differences.check(input, "emergency", emergency, result.emergency)
            differences.check(input, "self_harm", selfHarm, result.selfHarm)
        }

        @Test func `redflags_single golden`() throws {
            let golden = try Golden.load(.rules, "redflags_single", as: SingleCase.self)
            let table = HitTable(golden)
            var differences = Differences("redflags_single.json")
            let ran = golden.run { item in
                Self.compare(
                    RedFlags.check(item.text), table: table, input: item.text, hits: item.hits,
                    denied: item.denied, categories: item.categories, emergency: item.emergency,
                    selfHarm: item.selfHarm, into: &differences)
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        @Test func `redflags_conversation golden`() throws {
            let golden = try Golden.load(.rules, "redflags_conversation", as: ConversationCase.self)
            let table = HitTable(golden)
            var differences = Differences("redflags_conversation.json")
            let ran = golden.run { item in
                let input = "\(item.history.messages.map(\.content)) then \(item.text)"
                let result = RedFlags.checkConversation(item.text, history: item.history.messages)
                Self.compare(
                    result, table: table, input: input, hits: item.hits, denied: item.denied,
                    categories: item.categories, emergency: item.emergency, selfHarm: item.selfHarm,
                    into: &differences)
                differences.check(input, "fired", item.fired, result.fired)
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }
    }
}
