/// The active medicine a patient is asking to refill.
public struct RefillMatch: Sendable {
    /// The exact entry from active_meds.
    public let medicine: String
    public let cue: String
}

struct RefillTables: Sendable {
    let intents: PhraseList
    let bareRefills: PhraseList
    let nouns: PhraseList
    let symptoms: PhraseList
    let cancels: PhraseList
    let usuals: PhraseList
    let requests: PhraseList
    let classes: [Scalars: PhraseList]
    let drugNames: [Scalars: [[Scalars]]]
    let arabicToLatin: [Scalars: Scalars]
    let bareFiller: Set<Scalars>
    let refillNegators: [[Scalars]]
    let requestNegators: [[Scalars]]
    let politeWords: Set<Scalars>
    /// Every word of a medicine noun, a usual word or a class word, for `_is_medicine_alone`.
    let medicineAloneWords: Set<Scalars>
    /// Every word of a bare refill, and the filler, for `_is_bare_request`.
    let bareWords: Set<Scalars>
    let nounWords: Set<Scalars>

    init(file: RuleFile) throws {
        intents = try file.phraseList("_INTENTS")
        bareRefills = try file.phraseList("_BARE_REFILLS")
        nouns = try file.phraseList("_NOUNS")
        symptoms = try file.phraseList("_SYMPTOMS")
        cancels = try file.phraseList("_CANCELS")
        usuals = try file.phraseList("_USUALS")
        requests = try file.phraseList("_REQUESTS")
        let classRows = try file.phraseRows("_CLASSES")
        classes = Dictionary(classRows.map { ($0.key, PhraseList($0.phrases)) }, uniquingKeysWith: { $1 })
        drugNames = Dictionary(
            try file.phraseRows("_DRUG_NAMES").map { ($0.key, $0.phrases) }, uniquingKeysWith: { $1 })
        arabicToLatin = try file.wordMap("_ARABIC_TO_LATIN")
        bareFiller = try file.wordSet("_BARE_FILLER")
        refillNegators = try file.phrases("_REFILL_NEGATORS")
        requestNegators = try file.phrases("_REQUEST_NEGATORS")
        politeWords = try file.wordSet("_POLITE_WORDS")

        let noun = nouns.phrases.flatMap { $0 }
        let usual = usuals.phrases.flatMap { $0 }
        let classWords = classRows.flatMap(\.phrases).flatMap { $0 }
        nounWords = Set(noun)
        medicineAloneWords = Set(noun + usual + classWords)
        bareWords = Set(bareRefills.phrases.flatMap { $0 }).union(bareFiller)
    }
}

/// A line-by-line port of backend/ai/refill.py. A deflection needs a refill intent, a medicine
/// reference and that drug on the record. A symptom word, a problem with the medicine or a
/// question about it cancels it, because that must reach a nurse rather than a refill line.
public enum Refill {
    private static var tables: RefillTables { RuleTables.shared.refill }

    private static func drugKey(_ entry: Scalars) -> Scalars? {
        let words = RuleTables.shared.unicode.split(TextRules.normalise(entry))
        guard let first = words.first else { return nil }
        return tables.arabicToLatin[first] ?? first
    }

    /// A symptom or a problem with the medicine: a nurse must hear this.
    public static func blocksRefill(_ text: String) -> Bool {
        blocksRefill(TextRules.tokenise(text))
    }

    static func blocksRefill(_ tokens: [Token]) -> Bool {
        tables.symptoms.contains(in: tokens) || tables.cancels.contains(in: tokens)
    }

    private static func liveCue(_ tokens: [Token], _ list: PhraseList, negators: [[Scalars]]) -> Scalars? {
        for match in list.matches(in: tokens)
        where !TextRules.isNegated(tokens, cueStart: match.start, extra: negators) {
            return list.phrases[match.phrase].joined(with: [0x20])
        }
        return nil
    }

    private static func isAny(_ token: Token, of words: Set<Scalars>) -> Bool {
        words.contains(token.text) || token.forms.contains(where: words.contains)
    }

    /// True for a medicine noun first, and nothing but its name.
    private static func isMedicineAlone(_ tokens: [Token]) -> Bool {
        let tables = tables
        guard isAny(tokens[0], of: tables.nounWords) else { return false }
        return tokens.allSatisfy { token in
            tables.politeWords.contains(token.text) || isAny(token, of: tables.medicineAloneWords)
        }
    }

    private static func intentCue(_ tokens: [Token]) -> Scalars? {
        let tables = tables
        if let cue = liveCue(tokens, tables.intents, negators: tables.refillNegators) { return cue }
        if let usual = liveCue(tokens, tables.usuals, negators: tables.refillNegators),
            liveCue(tokens, tables.requests, negators: tables.requestNegators) != nil
                || isMedicineAlone(tokens)
        {
            return usual
        }
        return nil
    }

    private static func isBareRequest(_ tokens: [Token]) -> Bool {
        let bare = tables.bareWords
        return tokens.allSatisfy { isAny($0, of: bare) }
    }

    /// The active medicine a patient is asking to refill, if any.
    public static func detect(_ text: String, activeMeds: [String]) -> RefillMatch? {
        detect(text.scalars, activeMeds: activeMeds)
    }

    static func detect(_ text: Scalars, activeMeds: [String]) -> RefillMatch? {
        let tables = tables
        let tokens = TextRules.tokenise(text)
        if blocksRefill(tokens) { return nil }
        guard let cue = intentCue(tokens) else { return nil }

        let medicines = activeMeds.compactMap { entry in
            drugKey(entry.scalars).map { (entry: entry, drug: $0) }
        }.filter { !$0.drug.isEmpty }
        let hasNoun = tables.nouns.contains(in: tokens)
        for (entry, drug) in medicines {
            let names = [[drug]] + (tables.drugNames[drug] ?? [])
            if TextRules.containsAny(tokens, names) {
                return RefillMatch(medicine: entry, cue: cue.string)
            }
            if hasNoun, tables.classes[drug]?.contains(in: tokens) == true {
                return RefillMatch(medicine: entry, cue: cue.string)
            }
        }
        if let bareCue = liveCue(tokens, tables.bareRefills, negators: tables.refillNegators),
            medicines.count == 1, isBareRequest(tokens)
        {
            return RefillMatch(medicine: medicines[0].entry, cue: bareCue.string)
        }
        return nil
    }
}
