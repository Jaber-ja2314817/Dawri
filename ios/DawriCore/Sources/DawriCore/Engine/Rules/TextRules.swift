/// A word of normalised text and where it stands in its clause.
struct Token: Sendable {
    let text: Scalars
    let startsClause: Bool
    /// A cue may not span this token's left edge.
    let afterPunctuation: Bool
    /// `_proclitic_forms(text)`, worked out once because every matcher wants it.
    let forms: [Scalars]

    init(_ text: Scalars, startsClause: Bool, afterPunctuation: Bool = false) {
        self.text = text
        self.startsClause = startsClause
        self.afterPunctuation = afterPunctuation
        forms = TextRules.procliticForms(text)
    }
}

/// A line-by-line port of backend/ai/text.py. Every check that looks for words in patient text
/// goes through here, so diacritics, tatweel and letter variants cannot change what it sees.
enum TextRules {
    private static let newline: UInt32 = 0x0A
    private static let carriageReturn: UInt32 = 0x0D
    private static let space: UInt32 = 0x20
    private static let apostrophe: UInt32 = 0x27
    private static let fullStop: UInt32 = 0x2E
    private static let capitalSigma: UInt32 = 0x03A3
    private static let smallSigma: UInt32 = 0x03C3
    private static let finalSigma: UInt32 = 0x03C2
    /// No code point in here has a lower case, so a check can skip the property lookup.
    private static let caselessArabic: ClosedRange<UInt32> = 0x0590...0x08FF

    // MARK: normalise

    static func normalise(_ text: String) -> Scalars { normalise(text.scalars) }

    static func normalise(_ text: Scalars) -> Scalars {
        let tables = RuleTables.shared.text
        var out = compatibilityComposed(text)
        out.removeAll(where: tables.dropped.contains)
        out = lowered(translated(out, tables.charMap))
        out = spaced(unifiedLineBreaks(out, tables.lineBreaks))
        return RuleTables.shared.unicode.strip(out)
    }

    private static func compatibilityComposed(_ text: Scalars) -> Scalars {
        if text.allSatisfy({ $0 < 0x80 }) { return text }
        return text.string.precomposedStringWithCompatibilityMapping.scalars
    }

    private static func translated(_ text: Scalars, _ map: [UInt32: Scalars]) -> Scalars {
        var out: Scalars = []
        out.reserveCapacity(text.count)
        for point in text {
            if point >= 0x80, let replacement = map[point] {
                out += replacement
            } else {
                out.append(point)
            }
        }
        return out
    }

    /// `str.lower()`: the full lower case mapping of each code point, plus the one mapping that
    /// depends on context, capital sigma at the end of a word.
    private static func lowered(_ text: Scalars) -> Scalars {
        var out: Scalars = []
        out.reserveCapacity(text.count)
        for (index, point) in text.enumerated() {
            if point < 0x80 {
                out.append(point >= 0x41 && point <= 0x5A ? point + 32 : point)
            } else if caselessArabic.contains(point) {
                out.append(point)
            } else if point == capitalSigma {
                out.append(sigma(at: index, in: text))
            } else if let scalar = Unicode.Scalar(point) {
                out += scalar.properties.lowercaseMapping.scalars
            }
        }
        return out
    }

    /// CPython's handle_capital_sigma.
    private static func sigma(at index: Int, in text: Scalars) -> UInt32 {
        func property(_ point: UInt32, _ read: (Unicode.Scalar.Properties) -> Bool) -> Bool {
            Unicode.Scalar(point).map { read($0.properties) } ?? false
        }
        var before = index - 1
        while before >= 0, property(text[before], \.isCaseIgnorable) { before -= 1 }
        guard before >= 0, property(text[before], \.isCased) else { return smallSigma }
        var after = index + 1
        while after < text.count, property(text[after], \.isCaseIgnorable) { after += 1 }
        if after == text.count || !property(text[after], \.isCased) { return finalSigma }
        return smallSigma
    }

    /// `_LINE_BREAKS`: \r\n is one break, and each of the others is one break.
    private static func unifiedLineBreaks(_ text: Scalars, _ breaks: RangeTable) -> Scalars {
        var out: Scalars = []
        out.reserveCapacity(text.count)
        var index = 0
        while index < text.count {
            let point = text[index]
            index += 1
            if point == carriageReturn {
                if index < text.count, text[index] == newline { index += 1 }
                out.append(newline)
            } else {
                out.append(breaks.contains(point) ? newline : point)
            }
        }
        return out
    }

    /// `_HORIZONTAL_SPACE` then `_SPACE_AT_NEWLINE`. After the first, no two spaces touch, so the
    /// second is the same as dropping every space that touches a newline.
    private static func spaced(_ text: Scalars) -> Scalars {
        let isSpace = RuleTables.shared.unicode.space
        var runs: Scalars = []
        runs.reserveCapacity(text.count)
        for point in text {
            if point != newline, isSpace.contains(point) {
                if runs.last != space { runs.append(space) }
            } else {
                runs.append(point)
            }
        }
        var out: Scalars = []
        out.reserveCapacity(runs.count)
        for (index, point) in runs.enumerated() {
            let touchesNewline =
                (index > 0 && runs[index - 1] == newline)
                || (index + 1 < runs.count && runs[index + 1] == newline)
            if point != space || !touchesNewline { out.append(point) }
        }
        return out
    }

    // MARK: tokenise

    private static func gapBreaksClause(_ gap: ArraySlice<UInt32>, before: UInt32, after: UInt32) -> Bool {
        let unicode = RuleTables.shared.unicode
        if gap.count == 1, gap.first == fullStop, unicode.digit.contains(before), unicode.digit.contains(after) {
            return false  // decimal point, as in 38.5
        }
        return gap.contains(where: RuleTables.shared.text.clausePunctuation.contains)
    }

    static func tokenise(_ text: String) -> [Token] { tokenise(text.scalars) }

    /// `_WORD.finditer` over the normalised text, by hand, because `\w` is Python's.
    static func tokenise(_ text: Scalars) -> [Token] {
        let norm = normalise(text)
        let word = RuleTables.shared.unicode.word
        let clauseWords = RuleTables.shared.text.clauseWords
        var tokens: [Token] = []
        var previousEnd = 0
        var index = 0
        while index < norm.count {
            guard word.contains(norm[index]) else {
                index += 1
                continue
            }
            let start = index
            while index < norm.count, word.contains(norm[index]) { index += 1 }
            if index + 1 < norm.count, norm[index] == apostrophe, word.contains(norm[index + 1]) {
                index += 1
                while index < norm.count, word.contains(norm[index]) { index += 1 }
            }
            let text = Array(norm[start..<index])
            if tokens.isEmpty {
                tokens.append(Token(text, startsClause: true))
            } else {
                let punctuated = gapBreaksClause(
                    norm[previousEnd..<start], before: norm[previousEnd - 1], after: text[0])
                tokens.append(
                    Token(
                        text, startsClause: punctuated || clauseWords.contains(text),
                        afterPunctuation: punctuated))
            }
            previousEnd = index
        }
        return tokens
    }

    static func phraseTokens(_ phrase: String) -> [Scalars] {
        tokenise(phrase).map(\.text)
    }

    // MARK: negation

    private static func phraseEnds(_ tokens: [Token], at position: Int, _ phrase: [Scalars]) -> Bool {
        let start = position - phrase.count + 1
        guard start >= 0 else { return false }
        for (offset, word) in phrase.enumerated() where tokens[start + offset].text != word {
            return false
        }
        var index = start + 1
        while index <= position {
            if tokens[index].startsClause { return false }
            index += 1
        }
        return true
    }

    private static func isNegator(_ tokens: [Token], at position: Int) -> Bool {
        RuleTables.shared.text.negators.contains { phraseEnds(tokens, at: position, $0) }
    }

    /// An exception word, bare or with an Arabic proclitic.
    private static func isNegationException(_ token: Token) -> Bool {
        let exceptions = RuleTables.shared.text.negationExceptions
        return exceptions.contains(token.text) || token.forms.contains(where: exceptions.contains)
    }

    /// This token says the patient has the symptom. An Arabic word right after a negator is
    /// negated itself.
    private static func isAffirmation(_ tokens: [Token], at position: Int) -> Bool {
        let tables = RuleTables.shared.text
        let token = tokens[position]
        if tables.englishAffirmations.contains(token.text) { return true }
        guard
            tables.arabicAffirmations.contains(token.text)
                || token.forms.contains(where: tables.arabicAffirmations.contains)
        else { return false }
        return !isNegator(tokens, at: position - 1)
    }

    /// `is_negated`. `extra` adds negator phrases for one caller, and a caller that passes any
    /// gets no exception or affirmation words, because for those callers negation is the cautious
    /// way round.
    static func isNegated(
        _ tokens: [Token], cueStart: Int, window: Int = 3, extra: [[Scalars]] = []
    ) -> Bool {
        if tokens[cueStart].startsClause { return false }
        let hasExceptions = extra.isEmpty
        if hasExceptions, isAffirmation(tokens, at: cueStart) { return false }
        var position = cueStart - 1
        let lowest = max(cueStart - window, 0)
        while position >= lowest {
            if isNegator(tokens, at: position) || extra.contains(where: { phraseEnds(tokens, at: position, $0) }) {
                return true
            }
            if tokens[position].startsClause { return false }
            if hasExceptions, isNegationException(tokens[position]) || isAffirmation(tokens, at: position) {
                return false
            }
            position -= 1
        }
        return false
    }

    // MARK: matching

    /// `_proclitic_forms`, deduplicated as the Python set is. `_is_affirmation` and the matchers
    /// only ask whether a word is in here, so its order carries nothing.
    static func procliticForms(_ token: Scalars) -> [Scalars] {
        guard let first = token.first, first >= 0x80 else { return [] }
        let tables = RuleTables.shared.text
        var forms: [Scalars] = []
        func add(_ form: Scalars) {
            if !forms.contains(form) { forms.append(form) }
        }
        for proclitic in tables.proclitics where token.starts(with: proclitic) {
            let stem = Array(token[proclitic.count...])
            add(stem)
            if proclitic == tables.contractedProclitic { add(tables.article + stem) }
        }
        return forms
    }

    static func tokenMatches(_ cueToken: Scalars, _ text: Token) -> Bool {
        text.text == cueToken || text.forms.contains(cueToken)
    }

    static func hasLeadingWaw(_ cueToken: Scalars, _ textToken: Scalars) -> Bool {
        textToken != cueToken && textToken.starts(with: RuleTables.shared.text.waw)
    }

    /// The words after the first of `phrase` line up at `start`, not across punctuation.
    static func phraseFollows(_ phrase: [Scalars], at start: Int, in tokens: [Token]) -> Bool {
        guard start + phrase.count <= tokens.count else { return false }
        var offset = 1
        while offset < phrase.count {
            let token = tokens[start + offset]
            if token.afterPunctuation || !tokenMatches(phrase[offset], token) { return false }
            offset += 1
        }
        return true
    }

    /// `phrase_starts`, for a phrase that is not in a `PhraseList`.
    static func phraseStarts(_ tokens: [Token], _ phrase: [Scalars]) -> [Int] {
        guard let first = phrase.first else { return Array(0...tokens.count) }
        return tokens.indices.filter { start in
            tokenMatches(first, tokens[start]) && phraseFollows(phrase, at: start, in: tokens)
        }
    }

    static func containsAny(_ tokens: [Token], _ phrases: [[Scalars]]) -> Bool {
        phrases.contains { !phraseStarts(tokens, $0).isEmpty }
    }

    static func hasArabic(_ text: Scalars) -> Bool {
        text.contains(where: RuleTables.shared.text.arabicLetter.contains)
    }

    static func splitSentences(_ text: Scalars) -> [Scalars] {
        let unicode = RuleTables.shared.unicode
        var sentences: [Scalars] = []
        var start = 0
        for match in RuleTables.shared.regex.sentenceEnd.finditer(text) {
            sentences.append(unicode.strip(Array(text[start..<match.end])))
            start = match.end
        }
        sentences.append(unicode.strip(Array(text[start...])))
        return sentences.filter { !$0.isEmpty }
    }
}
