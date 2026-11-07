import Foundation
import Testing
@testable import DawriCore

private struct TokenRow: Decodable {
    let text: String
    let startsClause: Bool
    let afterPunctuation: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        text = try row.decode(String.self)
        let flags = try row.decode(Int.self)
        startsClause = flags & 1 != 0
        afterPunctuation = flags & 2 != 0
    }

    var token: Token {
        Token(text.scalars, startsClause: startsClause, afterPunctuation: afterPunctuation)
    }
}

private struct TextCase: Decodable {
    let input: String
    let normalised: String
    let tokens: [TokenRow]
    let phraseTokens: [String]
    let sentences: [String]
    let hasArabic: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        input = try row.decode(String.self)
        normalised = try row.decode(String.self)
        tokens = try row.decode([TokenRow].self)
        phraseTokens = try row.decode([String].self)
        sentences = try row.decode([String].self)
        hasArabic = try row.decode(Int.self) == 1
    }
}

private struct NegationCase: Decodable {
    let tokens: [TokenRow]
    let cueStart: Int
    let window: Int
    let extra: [[String]]
    let negated: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        tokens = try row.decode([TokenRow].self)
        cueStart = try row.decode(Int.self)
        window = try row.decode(Int.self)
        extra = try row.decode([[String]].self)
        negated = try row.decode(Int.self) == 1
    }
}

private struct ProcliticCase: Decodable {
    let token: String
    let forms: [String]
    let cueToken: String
    let matches: Bool
    let leadingWaw: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        token = try row.decode(String.self)
        forms = try row.decode([String].self)
        cueToken = try row.decode(String.self)
        matches = try row.decode(Int.self) == 1
        leadingWaw = try row.decode(Int.self) == 1
    }
}

extension Rules {
    @Suite("Rules: text goldens")
    struct TextGoldenTests {
        @Test func `text golden`() throws {
            let golden = try Golden.load(.rules, "text", as: TextCase.self)
            var differences = Differences("text.json")
            let ran = golden.run { item in
                let scalars = item.input.scalars
                differences.check(item.input, "normalise", item.normalised, TextRules.normalise(scalars).string)
                let tokens = TextRules.tokenise(scalars)
                differences.check(item.input, "tokens", item.tokens.map(\.text), tokens.map(\.text.string))
                differences.check(
                    item.input, "starts_clause", item.tokens.map(\.startsClause), tokens.map(\.startsClause))
                differences.check(
                    item.input, "after_punctuation", item.tokens.map(\.afterPunctuation),
                    tokens.map(\.afterPunctuation))
                differences.check(
                    item.input, "phrase_tokens", item.phraseTokens,
                    TextRules.phraseTokens(item.input).map(\.string))
                differences.check(
                    item.input, "split_sentences", item.sentences,
                    TextRules.splitSentences(scalars).map(\.string))
                differences.check(item.input, "has_arabic", item.hasArabic, TextRules.hasArabic(scalars))
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        @Test func `text_negation golden`() throws {
            let golden = try Golden.load(.rules, "text_negation", as: NegationCase.self)
            var differences = Differences("text_negation.json")
            let ran = golden.run { item in
                let found = TextRules.isNegated(
                    item.tokens.map(\.token), cueStart: item.cueStart, window: item.window,
                    extra: item.extra.map { $0.map(\.scalars) })
                let input = "\(item.tokens.map(\.text)) at \(item.cueStart) window \(item.window)"
                differences.check(input, "is_negated", item.negated, found)
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }

        @Test func `text_proclitics golden`() throws {
            let golden = try Golden.load(.rules, "text_proclitics", as: ProcliticCase.self)
            var differences = Differences("text_proclitics.json")
            let ran = golden.run { item in
                let forms = pythonSorted(TextRules.procliticForms(item.token.scalars))
                differences.check(item.token, "proclitic_forms", item.forms, forms.map(\.string))
                let token = Token(item.token.scalars, startsClause: false)
                differences.check(
                    item.token, "token_matches \(item.cueToken)", item.matches,
                    TextRules.tokenMatches(item.cueToken.scalars, token))
                differences.check(
                    item.token, "has_leading_waw \(item.cueToken)", item.leadingWaw,
                    TextRules.hasLeadingWaw(item.cueToken.scalars, token.text))
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }
    }
}
