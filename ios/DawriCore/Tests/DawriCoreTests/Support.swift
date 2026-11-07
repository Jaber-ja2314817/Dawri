import Foundation
import Testing
@testable import DawriCore

/// The repo, found from this file, so a test can read the sources it guards.
enum Repo {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // DawriCoreTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // DawriCore
        .deletingLastPathComponent() // ios
        .deletingLastPathComponent()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appending(path: path), encoding: .utf8)
    }

    static func dictionary(_ path: String) throws -> [String: String] {
        let data = try Data(contentsOf: root.appending(path: path))
        return try JSONDecoder().decode([String: String].self, from: data)
    }
}

enum Fixture {
    static var folder: URL {
        get throws {
            try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
        }
    }

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: try folder.appending(path: "\(name).json"))
    }

    static func decode<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
        try JSONDecoder().decode(type, from: try data(name))
    }
}

func decode<T: Decodable>(_ type: T.Type, json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

/// Keys that hold null are the same as absent keys to these models.
func withoutNulls(_ value: JSONValue) -> JSONValue {
    switch value {
    case .object(let fields):
        .object(fields.filter { $0.value != .null }.mapValues(withoutNulls))
    case .array(let items):
        .array(items.map(withoutNulls))
    default:
        value
    }
}

/// A store that keeps what it is given, or with `blocked`, refuses everything, as the web's
/// test does when localStorage throws.
final class MemoryStore: KeyValueStore {
    var values: [String: String]
    let blocked: Bool

    init(_ values: [String: String] = [:], blocked: Bool = false) {
        self.values = values
        self.blocked = blocked
    }

    func read(_ key: String) -> String? { blocked ? nil : values[key] }
    func write(_ value: String, for key: String) { if !blocked { values[key] = value } }
    func remove(_ key: String) { if !blocked { values[key] = nil } }
}
