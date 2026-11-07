import Foundation
import Testing
@testable import DawriCore

/// The namespace of every rules suite, so `swift test --filter Rules` finds them all.
enum Rules {}

/// Collects differences so a golden reports every failure count and the first few in full.
/// Text is compared by scalars, because `String ==` would hide the differences goldens exist for.
struct Differences {
    private var count = 0
    private let file: String
    private static let shown = 15

    init(_ file: String) { self.file = file }

    mutating func report(input: String, field: String, expected: String, found: String) {
        count += 1
        if count <= Self.shown {
            Issue.record(
                """
                \(file): \(field) differs
                  input    \(Self.visible(input))
                  expected \(Self.visible(expected))
                  found    \(Self.visible(found))
                """)
        }
    }

    mutating func check(_ input: String, _ field: String, _ expected: String, _ found: String) {
        if !sameScalars(expected, found) {
            report(input: input, field: field, expected: expected, found: found)
        }
    }

    mutating func check(_ input: String, _ field: String, _ expected: String?, _ found: String?) {
        switch (expected, found) {
        case (nil, nil): break
        case (let first?, let second?): check(input, field, first, second)
        default: report(input: input, field: field, expected: "\(expected ?? "nil")", found: "\(found ?? "nil")")
        }
    }

    mutating func check(_ input: String, _ field: String, _ expected: [String], _ found: [String]) {
        if expected.count != found.count || !zip(expected, found).allSatisfy(sameScalars) {
            report(input: input, field: field, expected: "\(expected)", found: "\(found)")
        }
    }

    mutating func check<T: Equatable>(_ input: String, _ field: String, _ expected: T, _ found: T) {
        if expected != found {
            report(input: input, field: field, expected: "\(expected)", found: "\(found)")
        }
    }

    /// Fails the test if anything differed.
    func finish(ran: Int) {
        if count > 0 { Issue.record("\(file): \(count) of \(ran) cases differ") }
    }

    private static func visible(_ text: String) -> String {
        let shown = text.unicodeScalars.map { scalar -> String in
            scalar.value < 0x20 || (0x7F...0xA0).contains(scalar.value) || (0x2028...0x2029).contains(scalar.value)
                ? "\\u{\(String(scalar.value, radix: 16))}" : String(scalar)
        }
        return shown.joined()
    }
}

/// [role, content, slot]: role 0 is user, 1 assistant.
struct RulesHistoryRow: Decodable {
    let message: ChatMessage

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        let role = try row.decode(Int.self)
        let content = try row.decode(String.self)
        let slot = try row.decode(String?.self)
        message = ChatMessage(role: role == 1 ? .assistant : .user, content: content, slot: slot)
    }
}

extension [RulesHistoryRow] {
    var messages: [ChatMessage] { map(\.message) }
}

/// A patient row of a golden header. Some are partial, as the tests that made them were, and
/// nothing reads a field Python could not have read.
func rulesPatient(from value: JSONValue) -> Patient {
    guard case .object(let fields) = value else { fatalError("a patient row is an object") }
    func text(_ key: String) -> String {
        if case .string(let found)? = fields[key] { return found }
        return ""
    }
    func list(_ key: String) -> [String] {
        guard case .array(let items)? = fields[key] else { return [] }
        return items.compactMap {
            if case .string(let found) = $0 { return found }
            return nil
        }
    }
    var age = 0
    if case .number(let found)? = fields["age"] { age = Int(found) }
    return Patient(
        id: text("id"), qidDemo: text("qid_demo"), fullNameEn: text("full_name_en"),
        fullNameAr: text("full_name_ar"), dob: text("dob"), age: age, sex: text("sex"),
        preferredLang: text("preferred_lang"), allergies: list("allergies"), chronic: list("chronic"),
        activeMeds: list("active_meds"), registeredCentre: Centre(id: "", nameEn: "", nameAr: ""),
        demo: false)
}

func rulesPatients<Case>(in golden: GoldenSet<Case>) -> [Patient] {
    guard case .array(let rows)? = golden.header["patients"] else { return [] }
    return rows.map(rulesPatient(from:))
}

func rulesStrings(_ value: JSONValue?) -> [String] {
    guard case .array(let items)? = value else { return [] }
    return items.compactMap {
        if case .string(let found) = $0 { return found }
        return nil
    }
}

/// JSONValue's own `==` compares text with `String ==`, so this walks it by scalars.
func rulesSameJSON(_ first: JSONValue, _ second: JSONValue) -> Bool {
    switch (first, second) {
    case (.null, .null): true
    case (.bool(let one), .bool(let two)): one == two
    case (.number(let one), .number(let two)): one == two
    case (.string(let one), .string(let two)): sameScalars(one, two)
    case (.array(let one), .array(let two)):
        one.count == two.count && zip(one, two).allSatisfy(rulesSameJSON)
    case (.object(let one), .object(let two)):
        one.count == two.count
            && one.allSatisfy { key, value in two[key].map { rulesSameJSON(value, $0) } ?? false }
    default: false
    }
}

/// One intake, in the `intake_keys` order of the golden header.
struct RulesIntakeRow: Decodable {
    let emergency: Bool
    let language: String
    let chiefComplaint: String
    let patientWords: String
    let duration: String?
    let severity: Int?
    let associated: [String]
    let selfMedication: [String]
    let service: String
    let confidence: Double
    let summary: String
    let refillRequest: String?
    let questionsAsked: Int
    let denied: [String]
    let concerns: String?

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        emergency = try row.decode(Bool.self)
        language = try row.decode(String.self)
        chiefComplaint = try row.decode(String.self)
        patientWords = try row.decode(String.self)
        duration = try row.decode(String?.self)
        severity = try row.decode(Int?.self)
        associated = try row.decode([String].self)
        selfMedication = try row.decode([String].self)
        service = try row.decode(String.self)
        confidence = try row.decode(Double.self)
        summary = try row.decode(String.self)
        refillRequest = try row.decode(String?.self)
        questionsAsked = try row.decode(Int.self)
        denied = try row.decode([String].self)
        concerns = try row.decode(String?.self)
    }
}

extension Differences {
    mutating func check(_ input: String, _ expected: RulesIntakeRow?, _ found: IntakeRecord?) {
        guard let expected, let found else {
            if (expected == nil) != (found == nil) {
                report(
                    input: input, field: "intake", expected: expected == nil ? "nil" : "an intake",
                    found: found == nil ? "nil" : "an intake")
            }
            return
        }
        check(input, "intake.emergency", expected.emergency, found.emergency)
        check(input, "intake.language", expected.language, found.language)
        check(input, "intake.chief_complaint", expected.chiefComplaint, found.chiefComplaint)
        check(input, "intake.patient_words", expected.patientWords, found.chiefComplaintPatientWords)
        check(input, "intake.duration", expected.duration, found.duration)
        check(input, "intake.severity", expected.severity, found.severity0To10)
        check(input, "intake.associated", expected.associated, found.associated)
        check(input, "intake.self_medication", expected.selfMedication, found.selfMedication)
        check(input, "intake.service", expected.service, found.service.rawValue)
        check(input, "intake.confidence", expected.confidence, found.serviceConfidence)
        check(input, "intake.summary", expected.summary, found.summaryForNurse)
        check(input, "intake.refill_request", expected.refillRequest, found.refillRequest)
        check(input, "intake.questions_asked", expected.questionsAsked, found.questionsAsked)
        check(input, "intake.denied", expected.denied, found.deniedRedFlags)
        check(input, "intake.concerns", expected.concerns, found.patientConcerns)
    }
}
