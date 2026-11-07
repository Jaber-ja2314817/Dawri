import Foundation
import Synchronization
import Testing
@testable import DawriCore

/// Moves only when a test moves it, in whole microseconds, as `common.Clock` does in Python.
final class TestClock: Sendable {
    private let micros: Mutex<Int64>

    init(_ start: Date) {
        micros = Mutex(ClinicTime.microseconds(of: start))
    }

    convenience init(_ stamp: String) throws {
        self.init(try #require(ClinicTime.parse(stamp)))
    }

    var now: Date { ClinicTime.date(microseconds: micros.withLock { $0 }) }

    /// `timedelta(seconds=)` rounds to the microsecond, half to even.
    func advance(seconds: Double) {
        micros.withLock { $0 += Int64((seconds * 1_000_000).rounded(.toNearestOrEven)) }
    }

    func advance(microseconds: Int64) {
        micros.withLock { $0 += microseconds }
    }
}

/// `db.new_id` with a counter in place of the random part.
final class CountingIds: Sendable {
    private let serial = Mutex(0)

    func next(_ prefix: String) -> String {
        let value = serial.withLock {
            $0 += 1
            return $0
        }
        let hex = String(value, radix: 16)
        return "\(prefix)_\(String(repeating: "0", count: 12 - hex.count))\(hex)"
    }
}

func makeEngine(_ clock: TestClock, _ ids: CountingIds = CountingIds()) -> QueueEngine {
    QueueEngine(clock: { clock.now }, newId: { ids.next($0) })
}

/// Everything a direct test starts from. Noon in Doha, on the seed.
struct ClinicFixture {
    let clock: TestClock
    let ids = CountingIds()
    var engine: QueueEngine
    var state: ClinicState

    init(simulateLoad: Bool = true, start: String = "2026-11-07T09:00:00.000000+00:00") throws {
        clock = try TestClock(start)
        engine = makeEngine(clock, ids)
        state = try ClinicState.fresh(engine: &engine, simulateLoad: simulateLoad)
    }

    mutating func newVisit(_ patient: String, status: VisitStatus = .intake) -> String {
        let id = ids.next("V")
        state.visits.append(
            VisitRecord(
                id: id, patientId: patient, status: status,
                createdAt: ClinicTime.iso(clock.now)))
        return id
    }
}

/// Deep equality by scalars. `JSONValue ==` would let canonically equivalent text pass.
func sameJSON(_ first: JSONValue, _ second: JSONValue) -> Bool {
    switch (first, second) {
    case (.null, .null): true
    case (.bool(let a), .bool(let b)): a == b
    case (.number(let a), .number(let b)): a == b
    case (.string(let a), .string(let b)): sameScalars(a, b)
    case (.array(let a), .array(let b)): a.count == b.count && zip(a, b).allSatisfy(sameJSON)
    case (.object(let a), .object(let b)):
        a.count == b.count && a.allSatisfy { key, value in
            b[key].map { sameJSON(value, $0) } ?? false
        }
    default: false
    }
}

func text(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value) else { return "\(value)" }
    return String(decoding: data, as: UTF8.self)
}

/// A value as JSON, with its keys that hold null dropped, as `withoutNulls` does.
func plainJSON(_ value: some Encodable) throws -> JSONValue {
    withoutNulls(try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value)))
}

extension JSONValue {
    var string: String? {
        if case .string(let value) = self { value } else { nil }
    }

    var double: Double? {
        if case .number(let value) = self { value } else { nil }
    }

    var int: Int? {
        double.map { Int($0) }
    }

    var array: [JSONValue]? {
        if case .array(let value) = self { value } else { nil }
    }

    var object: [String: JSONValue]? {
        if case .object(let value) = self { value } else { nil }
    }

    var isNull: Bool { self == .null }

    static func number(_ value: Int) -> JSONValue { .number(Double(value)) }
}

/// A drug row as the goldens hold it, with `allergy_tags` still the column's JSON text.
func goldenDrug(_ value: JSONValue) throws -> DrugRecord {
    let row = try #require(value.object)
    func column(_ key: String) throws -> String { try #require(row[key]?.string) }
    let tags = try column("allergy_tags")
    return DrugRecord(
        id: try column("id"), nameEn: try column("name_en"), nameAr: try column("name_ar"),
        form: try column("form"), defaultDose: try column("default_dose"),
        defaultFrequency: try column("default_frequency"),
        defaultDays: try #require(row["default_days"]?.int),
        allergyTags: try JSONDecoder().decode([String].self, from: Data(tags.utf8)),
        demoDefault: try #require(row["demo_default"]?.int))
}

/// `Aliases` in ios/Tools/export/clinic.py, so a run's random ids meet the golden's V1 and T1.
/// Both walk values in the same order, so the same ticket gets the same alias.
struct IdAliases {
    private static let pattern = try! NSRegularExpression(pattern: #"\b(V|tkt)_[0-9a-f]{12}\b"#)
    private var names: [String: String] = [:]
    private var ids: [String: String] = [:]
    private var visits = 0
    private var tickets = 0

    private mutating func alias(for id: String) -> String {
        if let known = names[id] { return known }
        let name: String
        if id.hasPrefix("V") {
            visits += 1
            name = "V\(visits)"
        } else {
            tickets += 1
            name = "T\(tickets)"
        }
        names[id] = name
        ids[name] = id
        return name
    }

    /// The real id behind an argument. An alias not seen yet is the id no ticket has, which
    /// the exporter passes on purpose: V_000000000000 or tkt_000000000000.
    mutating func resolve(_ argument: String) -> String {
        if let id = ids[argument] { return id }
        guard let kind = argument.first, kind == "V" || kind == "T",
              !argument.dropFirst().isEmpty, argument.dropFirst().allSatisfy(\.isNumber)
        else { return argument }
        let id = kind == "V" ? "V_000000000000" : "tkt_000000000000"
        names[id] = argument
        ids[argument] = id
        if kind == "V" { visits += 1 } else { tickets += 1 }
        return id
    }

    private mutating func swapped(_ value: String) -> String {
        guard value.contains("_") else { return value }
        let whole = value as NSString
        var result = ""
        var cursor = 0
        let range = NSRange(location: 0, length: whole.length)
        for match in Self.pattern.matches(in: value, range: range) {
            result += whole.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            result += alias(for: whole.substring(with: match.range))
            cursor = match.range.location + match.range.length
        }
        return result + whole.substring(from: cursor)
    }

    mutating func apply(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let text):
            return .string(swapped(text))
        case .array(let items):
            var mapped: [JSONValue] = []
            for item in items { mapped.append(apply(item)) }
            return .array(mapped)
        case .object(let fields):
            var mapped: [String: JSONValue] = [:]
            for key in fields.keys.sorted() {
                if let field = fields[key] { mapped[key] = apply(field) }
            }
            return .object(mapped)
        default:
            return value
        }
    }
}
