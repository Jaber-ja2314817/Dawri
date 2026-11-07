/// One rule hit: a category, the cue that fired, and its labels.
public struct RedFlagHit: Sendable {
    public let category: String
    public let cue: String
    public let labelEn: String
    public let labelAr: String
    /// `labelEn`, the key every dict in redflags.py uses.
    let label: Scalars

    init(category: String, cue: String, labelEn: String, labelAr: String) {
        self.category = category
        self.cue = cue
        self.labelEn = labelEn
        self.labelAr = labelAr
        label = labelEn.scalars
    }
}

public struct RedFlagResult: Sendable {
    public let hits: [RedFlagHit]
    public let denied: [RedFlagHit]
    /// Labels that ever fired, so may never stay denied. `sorted(fired)` in Python's order.
    public let fired: [String]
    let firedLabels: Set<Scalars>

    init(hits: [RedFlagHit], denied: [RedFlagHit], fired: Set<Scalars> = []) {
        self.hits = hits
        self.denied = denied
        firedLabels = fired
        self.fired = pythonSorted(fired).map(\.string)
    }

    public var emergency: Bool { !hits.isEmpty }

    /// `dict.fromkeys`, so `categories[0]` is the category of the first hit.
    public var categories: [String] { uniqued(hits.map(\.category.scalars)).map(\.string) }

    public var selfHarm: Bool {
        let category = RuleTables.shared.redFlags.selfHarmCategory
        return hits.contains { $0.category.scalars == category }
    }
}

/// A Python dict of label to hit: a key keeps its first position whatever happens to its value.
private struct HitsByLabel {
    private var order: [Scalars] = []
    private var values: [Scalars: RedFlagHit] = [:]

    /// `hits.setdefault(label, hit)`.
    mutating func setDefault(_ hit: RedFlagHit) {
        if values[hit.label] == nil {
            order.append(hit.label)
            values[hit.label] = hit
        }
    }

    /// `hits[label] = hit`.
    mutating func assign(_ hit: RedFlagHit) {
        setDefault(hit)
        values[hit.label] = hit
    }

    func contains(_ label: Scalars) -> Bool { values[label] != nil }

    var labels: [Scalars] { order }
    var hits: [RedFlagHit] { order.compactMap { values[$0] } }
}

struct RedFlagTables: Sendable {
    struct Cue: Sendable {
        let phrase: [Scalars]
        let neverNegated: Bool
        let hit: RedFlagHit
    }

    struct Compound: Sendable {
        let sides: Set<Int>
        let hit: RedFlagHit
    }

    let cues: [Cue]
    let cueList: PhraseList
    let yesWords: Set<Scalars>
    let sideList: PhraseList
    /// The side each phrase of `sideList` belongs to.
    let sideOfPhrase: [Int]
    let neverNegatedSides: Set<Int>
    let compounds: [Compound]
    let notTheSide: [Int: PhraseList]
    /// `_DENIED_WITH`: denying the key denies the value in that clause.
    let deniedWith: [Int: Int]
    let notHere: PhraseList
    let noAnswers: PhraseList
    let unsureAnswers: PhraseList
    let cueWords: Set<Scalars>
    let patientVoice: [Scalars: Scalars]
    let askedSymptoms: Set<Int>
    let labelAr: [Scalars: String]
    let deniedEn: (prefix: Scalars, separator: Scalars)
    let deniedAr: (prefix: Scalars, separator: Scalars)
    let wordPrefix: Scalars
    let wordPrefixTo: Scalars
    let wordSuffixes: [Scalars]
    let wordSuffixTo: Scalars
    let questionMarks: [Scalars]
    let selfHarmCategory: Scalars

    init(file: RuleFile) throws {
        var labels: [Scalars: String] = [:]
        var loaded: [Cue] = []
        for row in try file.rows("CUES") {
            guard let category = row[0] as? String, let phrase = row[1] as? String,
                let labelEn = row[2] as? String, let labelAr = row[3] as? String,
                let neverNegated = row[4] as? Bool, let tokens = row[5] as? [String]
            else { throw RuleFileError.wrongShape("CUES") }
            labels[labelEn.scalars] = labelAr
            loaded.append(
                Cue(
                    phrase: tokens.map(\.scalars), neverNegated: neverNegated,
                    hit: RedFlagHit(category: category, cue: phrase, labelEn: labelEn, labelAr: labelAr)))
        }
        for row in try file.rows("_LABEL_AR") {
            guard let labelEn = row[0] as? String, let labelAr = row[1] as? String else {
                throw RuleFileError.wrongShape("_LABEL_AR")
            }
            labels[labelEn.scalars] = labelAr
        }
        cues = loaded
        cueList = PhraseList(loaded.map(\.phrase))
        labelAr = labels
        yesWords = try file.wordSet("YES_WORDS")

        let sideRows = try file.phraseRows("_SIDES")
        var sides: [Scalars: Int] = [:]
        for (index, row) in sideRows.enumerated() { sides[row.key] = index }
        func side(_ name: Scalars) throws -> Int {
            guard let index = sides[name] else { throw RuleFileError.missing("side \(name.string)") }
            return index
        }
        sideList = PhraseList(sideRows.flatMap(\.phrases))
        sideOfPhrase = sideRows.enumerated().flatMap { index, row in
            Array(repeating: index, count: row.phrases.count)
        }
        neverNegatedSides = Set(try file.words("_NEVER_NEGATED_SIDES").map(side))
        askedSymptoms = Set(try file.words("_ASKED_SYMPTOMS").map(side))

        let joiner = try file.file("literals").text("compound_joiner")
        compounds = try file.rows("_COMPOUNDS").map { row in
            guard let names = row[0] as? [String], let category = row[1] as? String,
                let label = row[2] as? String, let arabic = labels[label.scalars]
            else { throw RuleFileError.wrongShape("_COMPOUNDS") }
            return Compound(
                sides: Set(try names.map { try side($0.scalars) }),
                hit: RedFlagHit(
                    category: category, cue: names.map(\.scalars).joined(with: joiner.scalars).string,
                    labelEn: label, labelAr: arabic))
        }
        var notThe: [Int: PhraseList] = [:]
        for row in try file.phraseRows("_NOT_THE_SIDE") {
            notThe[try side(row.key)] = PhraseList(row.phrases)
        }
        notTheSide = notThe
        var with: [Int: Int] = [:]
        for (key, value) in try file.wordMap("_DENIED_WITH") { with[try side(key)] = try side(value) }
        deniedWith = with

        notHere = try file.phraseList("_NOT_HERE")
        noAnswers = try file.phraseList("_NO_ANSWERS")
        unsureAnswers = try file.phraseList("_UNSURE_ANSWERS")
        cueWords = try file.wordSet("_CUE_WORDS")
        patientVoice = try file.wordMap("_PATIENT_VOICE")

        let denied = try file.file("denied_text")
        let en = try denied.file("en")
        let ar = try denied.file("ar")
        deniedEn = (try en.scalars("prefix"), try en.scalars("separator"))
        deniedAr = (try ar.scalars("prefix"), try ar.scalars("separator"))

        let literals = try file.file("literals")
        wordPrefix = try literals.scalars("patient_word_prefix")
        wordPrefixTo = try literals.scalars("patient_word_prefix_to")
        wordSuffixes = try literals.words("patient_word_suffixes")
        wordSuffixTo = try literals.scalars("patient_word_suffix_to")
        questionMarks = try literals.words("question_marks")
        selfHarmCategory = try literals.scalars("self_harm_category")
    }
}

/// One line of a chat, as the rules read it: `{"role", "content", "slot"}`.
struct ChatLine: Sendable {
    let isAssistant: Bool
    let content: Scalars
    let slot: Scalars?

    init(_ message: ChatMessage) {
        isAssistant = message.role == .assistant
        content = message.content.scalars
        slot = message.slot?.scalars
    }

    init(user content: Scalars) {
        isAssistant = false
        self.content = content
        slot = nil
    }
}

/// A line-by-line port of backend/ai/redflags.py: layer 1 of the safety design. The cue list has
/// not been reviewed by a clinician. It runs on every patient message, and nothing can clear a hit.
public enum RedFlags {
    private static var tables: RedFlagTables { RuleTables.shared.redFlags }

    /// Run every cue over one piece of text. Repeats fire if any occurrence is not negated.
    public static func check(_ text: String) -> RedFlagResult { check(text.scalars) }

    static func check(_ text: Scalars) -> RedFlagResult {
        let tables = tables
        let tokens = TextRules.tokenise(text)
        var hits = HitsByLabel()
        var denied = HitsByLabel()
        for match in tables.cueList.matches(in: tokens) {
            let cue = tables.cues[match.phrase]
            let negated =
                !cue.neverNegated
                && !TextRules.hasLeadingWaw(cue.phrase[0], tokens[match.start].text)
                && TextRules.isNegated(tokens, cueStart: match.start)
            if negated {
                denied.setDefault(cue.hit)
            } else {
                hits.setDefault(cue.hit)
            }
        }
        return RedFlagResult(
            hits: hits.hits, denied: denied.hits.filter { !hits.contains($0.label) })
    }

    /// `means_yes`.
    static func meansYes(_ tokens: [Token]) -> Bool {
        guard let first = tokens.first else { return false }
        return tables.yesWords.contains(first.text)
    }

    private static func meansNo(_ tokens: [Token]) -> Bool {
        tables.noAnswers.opens(tokens) && !tables.unsureAnswers.opens(tokens)
    }

    private static func patientWord(_ word: Scalars) -> Scalars {
        let tables = tables
        if let voiced = tables.patientVoice[word] { return voiced }
        var forms: [Scalars] = []
        if word.starts(with: tables.wordPrefix) {
            forms.append(tables.wordPrefixTo + word.dropFirst())
        }
        if tables.wordSuffixes.contains(where: word.endsWith) {
            let stem = Array(word.dropLast())
            forms += [stem + tables.wordSuffixTo, stem]
        }
        return forms.first(where: tables.cueWords.contains) ?? word
    }

    /// A question as the patient would say it, because cues are in the first person.
    private static func inPatientVoice(_ question: Scalars) -> Scalars {
        let norm = TextRules.normalise(question)
        var out: Scalars = []
        var position = 0
        for match in RuleTables.shared.regex.patientVoiceWord.finditer(norm) {
            out += norm[position..<match.start]
            out += patientWord(Array(norm[match.start..<match.end]))
            position = match.end
        }
        out += norm[position...]
        return out
    }

    private static func readSides(_ text: Scalars) -> (live: Set<Int>, denied: Set<Int>) {
        struct Mention {
            let side: Int
            let clause: Int
            let negated: Bool
        }
        struct Denial: Hashable {
            let side: Int
            let clause: Int
        }

        let tables = tables
        let tokens = TextRules.tokenise(text)
        var clauses: [Int] = []
        clauses.reserveCapacity(tokens.count)
        var clause = 0
        for token in tokens {
            if token.startsClause { clause += 1 }
            clauses.append(clause)
        }
        var elsewhere = Set<Int>()
        for match in tables.notHere.matches(in: tokens) {
            let phrase = tables.notHere.phrases[match.phrase]
            if tokens[match.start].text == phrase[0] { elsewhere.insert(match.start + phrase.count) }
        }
        var notThis: [Int: Set<Int>] = [:]
        for (side, list) in tables.notTheSide { notThis[side] = list.wordsInside(tokens) }

        var mentions: [Mention] = []
        for match in tables.sideList.matches(in: tokens) {
            let side = tables.sideOfPhrase[match.phrase]
            if notThis[side]?.contains(match.start) == true { continue }
            let negated =
                !tables.neverNegatedSides.contains(side)
                && !TextRules.hasLeadingWaw(
                    tables.sideList.phrases[match.phrase][0], tokens[match.start].text)
                && (TextRules.isNegated(tokens, cueStart: match.start) || elsewhere.contains(match.start))
            mentions.append(Mention(side: side, clause: clauses[match.start], negated: negated))
        }
        let denials = Set(mentions.filter(\.negated).map { Denial(side: $0.side, clause: $0.clause) })
        var live = Set<Int>()
        for mention in mentions where !mention.negated {
            if let partner = tables.deniedWith[mention.side],
                denials.contains(Denial(side: partner, clause: mention.clause))
            {
                continue
            }
            live.insert(mention.side)
        }
        return (live, Set(denials.map(\.side)))
    }

    private static func compoundHits(_ spoken: [Scalars], asked: Set<Int>) -> [RedFlagHit] {
        var live = asked
        for text in spoken { live.formUnion(readSides(text).live) }
        return tables.compounds.filter { live.isSuperset(of: $0.sides) }.map(\.hit)
    }

    /// The last question in an assistant message, or nothing if it asked none.
    private static func question(in message: ChatLine) -> Scalars {
        let marks = tables.questionMarks
        let asked = TextRules.splitSentences(message.content).filter { sentence in
            marks.contains { sentence.containsRun($0) }
        }
        return asked.last.map(inPatientVoice) ?? []
    }

    /// Every patient message, each with the question it replies to, or nothing.
    private static func replies(_ history: [ChatLine], _ text: Scalars) -> [(said: Scalars, question: Scalars)] {
        var replies: [(said: Scalars, question: Scalars)] = []
        var asked: Scalars = []
        for message in history + [ChatLine(user: text)] {
            if message.isAssistant {
                asked = question(in: message)
            } else {
                replies.append((message.content, asked))
                asked = []
            }
        }
        return replies
    }

    /// Sides named only in a question that a reply kept alive, on any turn so far.
    private static func askedSides(_ history: [ChatLine], _ text: Scalars) -> Set<Int> {
        let tables = tables
        var raised = Set<Int>()
        for (said, question) in replies(history, text) {
            if question.isEmpty || meansNo(TextRules.tokenise(said)) { continue }
            let asked = readSides(question).live
            let (live, denied) = readSides(said)
            raised.formUnion(asked.intersection(tables.askedSymptoms).subtracting(denied))
            for compound in tables.compounds where !live.intersection(compound.sides).subtracting(asked).isEmpty {
                raised.formUnion(asked.intersection(compound.sides).subtracting(denied))
            }
        }
        return raised
    }

    /// The rules for one new message, read with everything said before it. `history` does not
    /// include `text`.
    public static func checkConversation(_ text: String, history: [ChatMessage] = []) -> RedFlagResult {
        checkConversation(text.scalars, history: history.map(ChatLine.init))
    }

    static func checkConversation(_ text: Scalars, history: [ChatLine]) -> RedFlagResult {
        let answers = replies(history, text).map { said, question in
            (said, meansYes(TextRules.tokenise(said)) ? question : Scalars())
        }
        let spoken = answers.flatMap { [$0.0, $0.1] }.filter { !$0.isEmpty }
        let last = answers[answers.count - 1]
        let current = [last.0, last.1].filter { !$0.isEmpty }.map { check($0) }

        var hits = HitsByLabel()
        for result in current {
            for hit in result.hits { hits.assign(hit) }
        }
        for hit in compoundHits(spoken, asked: askedSides(history, text)) { hits.setDefault(hit) }

        var fired = Set(hits.labels)
        for part in spoken {
            for hit in check(part).hits { fired.insert(hit.label) }
        }
        var denied = HitsByLabel()
        for result in current {
            for hit in result.denied { denied.assign(hit) }
        }
        return RedFlagResult(
            hits: hits.hits, denied: denied.hits.filter { !fired.contains($0.label) }, fired: fired)
    }

    /// The Arabic for an English cue label. An unknown one stays as it is.
    public static func labelAr(_ label: String) -> String {
        tables.labelAr[label.scalars] ?? label
    }

    /// The nurse-facing line, or an empty string when nothing was denied.
    public static func deniedText(_ labels: [String], lang: String = "en") -> String {
        deniedText(labels.map(\.scalars), lang: lang.scalars).string
    }

    static func deniedText(_ labels: [Scalars], lang: Scalars) -> Scalars {
        let unique = uniqued(labels)
        if unique.isEmpty { return [] }
        let tables = tables
        if lang.starts(with: "ar".scalars) {
            let arabic = unique.map { tables.labelAr[$0]?.scalars ?? $0 }
            return tables.deniedAr.prefix + arabic.joined(with: tables.deniedAr.separator)
        }
        return tables.deniedEn.prefix + unique.joined(with: tables.deniedEn.separator)
    }
}
