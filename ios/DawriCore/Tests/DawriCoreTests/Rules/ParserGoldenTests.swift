import Foundation
import Testing
@testable import DawriCore

private struct ParserCase: Decodable {
    let text: String
    let complaints: [String]
    let medicines: [String]
    let duration: String?
    let durationTagged: String?
    let severity: Int?
    let severityLoose: Int?
    let languageFromEn: String
    let languageFromAr: String

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        text = try row.decode(String.self)
        complaints = try row.decode([String].self)
        medicines = try row.decode([String].self)
        duration = try row.decode(String?.self)
        durationTagged = try row.decode(String?.self)
        severity = try row.decode(Int?.self)
        severityLoose = try row.decode(Int?.self)
        languageFromEn = try row.decode(String.self)
        languageFromAr = try row.decode(String.self)
    }
}

private struct QuestionCountCase: Decodable {
    let history: [RulesHistoryRow]
    let count: Int

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        history = try row.decode([RulesHistoryRow].self)
        count = try row.decode(Int.self)
    }
}

extension Rules {
    @Suite("Rules: parser goldens")
    struct ParserGoldenTests {
        @Test func `parsers golden`() throws {
            let golden = try Golden.load(.rules, "parsers", as: ParserCase.self)
            var differences = Differences("parsers.json")
            let ran = golden.run { item in
                let text = item.text
                differences.check(text, "find_complaints", item.complaints, Scripted.findComplaints(text))
                differences.check(text, "parse_medicines", item.medicines, Scripted.parseMedicines(text))
                differences.check(text, "parse_duration", item.duration, Scripted.parseDuration(text))
                differences.check(
                    text, "parse_duration tagged", item.durationTagged, Scripted.parseDuration(text, tagged: true))
                differences.check(text, "parse_severity", item.severity, Scripted.parseSeverity(text))
                differences.check(
                    text, "parse_severity loose", item.severityLoose, Scripted.parseSeverity(text, loose: true))
                differences.check(
                    text, "detect_lang en", item.languageFromEn, Scripted.detectLang(text, current: "en"))
                differences.check(
                    text, "detect_lang ar", item.languageFromAr, Scripted.detectLang(text, current: "ar"))
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        @Test func `parsers_question_count golden`() throws {
            let golden = try Golden.load(.rules, "parsers_question_count", as: QuestionCountCase.self)
            var differences = Differences("parsers_question_count.json")
            let ran = golden.run { item in
                differences.check(
                    "\(item.history.messages.map(\.content))", "question_count", item.count,
                    Scripted.questionCount(item.history.messages))
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }
    }
}
