import Foundation
import Testing
@testable import DawriCore

private struct ApiRow: Decodable, Sendable {
    let walk: String
    let step: Int
    let actor: String
    let method: String
    let path: String
    let request: JSONValue
    let status: Int
    let response: JSONValue

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        walk = try row.decode(String.self)
        step = try row.decode(Int.self)
        actor = try row.decode(String.self)
        method = try row.decode(String.self)
        path = try row.decode(String.self)
        request = try row.decode(JSONValue.self)
        status = try row.decode(Int.self)
        response = try row.decode(JSONValue.self)
    }
}

/// [actor, method, path, request], a step a refusal needs first.
private struct SetupRow: Decodable, Sendable {
    let actor: String
    let method: String
    let path: String
    let request: JSONValue

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        actor = try row.decode(String.self)
        method = try row.decode(String.self)
        path = try row.decode(String.self)
        request = try row.decode(JSONValue.self)
    }
}

private struct RefusalRow: Decodable, Sendable {
    let name: String
    let setup: [SetupRow]
    let actor: String
    let method: String
    let path: String
    let request: JSONValue
    let status: Int
    let response: JSONValue

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        name = try row.decode(String.self)
        setup = try row.decode([SetupRow].self)
        actor = try row.decode(String.self)
        method = try row.decode(String.self)
        path = try row.decode(String.self)
        request = try row.decode(JSONValue.self)
        status = try row.decode(Int.self)
        response = try row.decode(JSONValue.self)
    }
}

private func optional(_ value: JSONValue) -> JSONValue? {
    value == .null ? nil : value
}

/// `{error, message, ...}`, the way `api_error` renders a refusal.
private func body(of error: ClinicError) -> JSONValue {
    var fields = error.extra
    fields["error"] = .string(error.code)
    fields["message"] = .string(error.message)
    if let arabic = error.messageAr { fields["message_ar"] = .string(arabic) }
    return .object(fields)
}

extension Local {
    @Suite("Local: API replay")
    struct ApiReplayTests {
        /// Fails the test with where and what, because a JSON diff is the only useful message.
        private static func check(
            _ pairs: inout AliasPairs, label: String, status: Int, want: Int, expected: JSONValue,
            found: JSONValue
        ) {
            #expect(status == want, "\(label)")
            if !pairs.same(withoutNulls(expected), withoutNulls(found)) {
                Issue.record("\(label)\n  expected \(text(withoutNulls(expected)))\n  found    \(text(withoutNulls(found)))")
            }
        }

        private static func replay(_ rows: [ApiRow]) async throws -> Int {
            let replayer = try ApiReplayer()
            var ran = 0
            for row in rows {
                let label = "\(row.walk) \(row.step): \(row.actor) \(row.method) \(row.path)"
                let answer = try await replayer.run(
                    actor: row.actor, method: row.method, rawPath: row.path,
                    request: optional(row.request), response: optional(row.response))
                ran += 1
                if row.actor == "harness" || row.actor == "clock" { continue }
                if let refused = answer.refused {
                    check(
                        &replayer.pairs, label: label, status: refused.status, want: row.status,
                        expected: row.response, found: body(of: refused))
                } else if let expected = answer.expected, let found = answer.found {
                    if !["nurse", "doctor", "pharmacist"].contains(row.actor), row.method == "GET" {
                        // The model is the lens, so nothing it drops can hide a difference.
                        #expect(sameJSON(withoutNulls(row.response), expected), "\(label) lost a field")
                    }
                    check(
                        &replayer.pairs, label: label, status: 200, want: row.status,
                        expected: expected, found: found)
                } else {
                    Issue.record("\(label) produced nothing to compare")
                }
            }
            return ran
        }

        @Test func `every recorded response of every walk matches`() async throws {
            let golden = try Golden.load(.journeys, "api", as: ApiRow.self)
            var walks: [String: [ApiRow]] = [:]
            for row in golden.cases { walks[row.walk, default: []].append(row) }
            #expect(walks.count == 16)
            let ran = try await withThrowingTaskGroup(of: Int.self) { group in
                for rows in walks.values {
                    group.addTask { try await Self.replay(rows) }
                }
                return try await group.reduce(0, +)
            }
            #expect(ran == golden.count)
        }

        private static func replay(_ row: RefusalRow) async throws {
            let replayer = try ApiReplayer()
            for step in row.setup {
                let answer = try await replayer.run(
                    actor: step.actor, method: step.method, rawPath: step.path,
                    request: optional(step.request), response: nil)
                #expect(answer.refused == nil, "\(row.name): \(step.path) \(answer.refused?.code ?? "")")
            }
            let answer = try await replayer.run(
                actor: row.actor, method: row.method, rawPath: row.path,
                request: optional(row.request), response: nil)
            guard let refused = answer.refused else {
                Issue.record("\(row.name) was not refused")
                return
            }
            let want = try #require(row.response.object)
            #expect(refused.status == row.status, "\(row.name)")
            #expect(refused.code == want["error"]?.string, "\(row.name)")
            check(
                &replayer.pairs, label: row.name, status: refused.status, want: row.status,
                expected: row.response, found: body(of: refused))
        }

        @Test func `every refusal matches on status, code, message and message_ar`() async throws {
            let golden = try Golden.load(.journeys, "refusals", as: RefusalRow.self)
            let ran = try await withThrowingTaskGroup(of: Int.self) { group in
                for row in golden.cases {
                    group.addTask {
                        try await Self.replay(row)
                        return 1
                    }
                }
                return try await group.reduce(0, +)
            }
            #expect(ran == golden.count)
        }
    }
}
