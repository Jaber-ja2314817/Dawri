import Foundation
import Testing
@testable import DawriCore

/// A match cell is an offset for start and end, and [start, end] or null for a group.
private enum MatchCell: Decodable {
    case offset(Int)
    case group(Int, Int)
    case absent

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .absent
        } else if let offset = try? container.decode(Int.self) {
            self = .offset(offset)
        } else {
            let span = try container.decode([Int].self)
            self = .group(span[0], span[1])
        }
    }

    var text: String {
        switch self {
        case .offset(let value): "\(value)"
        case .group(let start, let end): "\(start)-\(end)"
        case .absent: "nil"
        }
    }
}

private struct RegexCase: Decodable {
    let pattern: String
    let input: String
    let matches: [[MatchCell]]

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        pattern = try row.decode(String.self)
        input = try row.decode(String.self)
        matches = try row.decode([[MatchCell]].self)
    }
}

extension Rules {
    @Suite("Rules: regex golden")
    struct RegexGoldenTests {
        @Test func `regex golden`() throws {
            let golden = try Golden.load(.rules, "regex", as: RegexCase.self)
            var differences = Differences("regex.json")
            var seen = Set<String>()
            let ran = try golden.run { item in
                seen.insert(item.pattern)
                let pattern = try #require(RuleTables.shared.regex.named(item.pattern.scalars), "\(item.pattern)")
                let found = pattern.finditer(item.input.scalars).map { match in
                    let groups = match.groups.map { group in
                        group.map { "\($0.lowerBound)-\($0.upperBound)" } ?? "nil"
                    }
                    return (["\(match.start)", "\(match.end)"] + groups).joined(separator: " ")
                }
                let expected = item.matches.map { $0.map(\.text).joined(separator: " ") }
                differences.check(item.input, item.pattern, expected, found)
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
            #expect(seen.count > 20)
        }
    }
}
