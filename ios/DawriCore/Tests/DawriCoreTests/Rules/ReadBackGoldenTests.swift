import Foundation
import Testing
@testable import DawriCore

private struct ReadBackCase: Decodable {
    let text: String
    let allowed: [String]
    let ok: Bool
    let reasons: [String]

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        text = try row.decode(String.self)
        allowed = try row.decode([String].self)
        ok = try row.decode(Int.self) == 1
        reasons = try row.decode([String].self)
    }
}

private struct SummaryFacts: Decodable {
    let chiefComplaint: String
    let patientWords: String
    let duration: String?
    let severity: Int?
    let medicines: [String]
    let denied: [String]

    enum CodingKeys: String, CodingKey {
        case chiefComplaint = "chief_complaint"
        case patientWords = "chief_complaint_patient_words"
        case duration
        case severity = "severity_0_10"
        case medicines = "self_medication"
        case denied = "denied_red_flags"
    }

    var facts: ReadBackFacts {
        ReadBackFacts(
            chiefComplaint: chiefComplaint, chiefComplaintPatientWords: patientWords, duration: duration,
            severity0To10: severity, selfMedication: medicines, deniedRedFlags: denied)
    }
}

private struct SummaryCase: Decodable {
    let intake: SummaryFacts
    let lang: String
    let reply: String
    let isPlainLine: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        intake = try row.decode(SummaryFacts.self)
        lang = try row.decode(String.self)
        reply = try row.decode(String.self)
        isPlainLine = try row.decode(Int.self) == 1
    }
}

extension Rules {
    @Suite("Rules: read-back goldens")
    struct ReadBackGoldenTests {
        @Test func `readback golden`() throws {
            let golden = try Golden.load(.rules, "readback", as: ReadBackCase.self)
            var differences = Differences("readback.json")
            let ran = golden.run { item in
                let result = ReadBackCheck.check(item.text, allowedMeds: item.allowed)
                differences.check(item.text, "ok", item.ok, result.ok)
                differences.check(item.text, "reasons", item.reasons, result.reasons.map(\.rawValue))
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        /// The patient reads what this decides, so both outcomes must appear in the golden.
        @Test func `readback_summary golden`() throws {
            let golden = try Golden.load(.rules, "readback_summary", as: SummaryCase.self)
            var differences = Differences("readback_summary.json")
            var plain = 0
            let ran = golden.run { item in
                let reply = Scripted.summaryReply(item.intake.facts, lang: item.lang)
                let key = LanguageKey(item.lang.scalars)
                differences.check(item.intake.patientWords, "reply", item.reply, reply)
                differences.check(
                    item.intake.patientWords, "is_plain_line", item.isPlainLine,
                    reply.scalars == RuleTables.shared.simulated.summaryPlain[key])
                if item.isPlainLine { plain += 1 }
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
            #expect(plain > 0)
            #expect(plain < ran)
        }
    }
}
