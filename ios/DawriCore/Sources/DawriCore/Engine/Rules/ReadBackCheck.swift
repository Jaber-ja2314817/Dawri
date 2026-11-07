/// What `check_reply` found wrong. The order of the cases is the order `_result` reports them.
public enum ReadBackReason: String, Sendable, CaseIterable {
    case diagnosis
    case drugDose = "drug_dose"
    case treatmentAdvice = "treatment_advice"
    case queueNumber = "queue_number"
}

public struct ReadBackResult: Sendable {
    public let ok: Bool
    public let reasons: [ReadBackReason]
}

struct FilterTables: Sendable {
    let drugNames: [Scalars: [Scalars]]
    /// `_DRUG_PHRASES` in source order.
    let drugs: [(canonical: Scalars, phrases: PhraseList)]
    let allDrugPhrases: PhraseList
    let diseaseTerms: PhraseList
    let conditionTriggers: PhraseList
    let historyOpeners: [[Scalars]]
    let secondPerson: PhraseList
    let conditionOpeners: PhraseList
    let reportingVerbs: Set<Scalars>
    let symptoms: PhraseList
    let guessOpeners: PhraseList
    let diagnosisWords: PhraseList
    let refusals: Set<Scalars>
    let tookWords: PhraseList
    let adviceTriggers: PhraseList
    let imperatives: Set<Scalars>
    let harmlessOrders: [[Scalars]]
    let leadIns: Set<Scalars>
    let unitCanonical: [Scalars: Scalars]
    let numberWords: [Scalars: Scalars]
    let queueTerms: PhraseList
    let queueWords: PhraseList
    let placeWords: PhraseList
    let waitTerms: PhraseList
    let questionOpeners: Set<Scalars>
    let questionSubjects: Set<Scalars>
    let sentenceClosers: Set<UInt32>
    let questionMarks: [Scalars]
    let joinedWaw: Scalars
    let anyWord: Scalars
    let useWord: Scalars
    let ofWord: Scalars
    let ofOrderWord: Scalars
    let twoTablets: Scalars
    let statementJoiner: Scalars

    init(file: RuleFile) throws {
        let names = try file.rows("DRUG_NAMES")
        var byName: [Scalars: [Scalars]] = [:]
        for row in names {
            guard let canonical = row[0] as? String, let forms = row[1] as? [String] else {
                throw RuleFileError.wrongShape("DRUG_NAMES")
            }
            byName[canonical.scalars] = forms.map(\.scalars)
        }
        drugNames = byName
        let phraseRows = try file.phraseRows("_DRUG_PHRASES")
        drugs = phraseRows.map { ($0.key, PhraseList($0.phrases)) }
        allDrugPhrases = PhraseList(phraseRows.flatMap(\.phrases))
        diseaseTerms = try file.phraseList("DISEASE_TERMS")
        conditionTriggers = try file.phraseList("_CONDITION_TRIGGERS")
        historyOpeners = try file.phrases("_HISTORY_OPENERS")
        secondPerson = try file.phraseList("_SECOND_PERSON")
        conditionOpeners = try file.phraseList("_CONDITION_OPENERS")
        reportingVerbs = try file.wordSet("_REPORTING_VERBS")
        symptoms = try file.phraseList("_SYMPTOMS")
        guessOpeners = try file.phraseList("_GUESS_OPENERS")
        diagnosisWords = try file.phraseList("_DIAGNOSIS_WORDS")
        refusals = try file.wordSet("_REFUSALS")
        tookWords = try file.phraseList("_TOOK_WORDS")
        adviceTriggers = try file.phraseList("_ADVICE_TRIGGERS")
        imperatives = try file.wordSet("_IMPERATIVES")
        harmlessOrders = try file.phrases("_HARMLESS_ORDERS")
        leadIns = try file.wordSet("_LEAD_INS")
        unitCanonical = try file.wordMap("_UNIT_CANONICAL")
        numberWords = try file.wordMap("_NUMBER_WORDS")
        queueTerms = try file.phraseList("_QUEUE_TERMS")
        queueWords = try file.phraseList("_QUEUE_WORDS")
        placeWords = try file.phraseList("_PLACE_WORDS")
        waitTerms = try file.phraseList("_WAIT_TERMS")
        questionOpeners = try file.wordSet("_QUESTION_OPENERS")
        questionSubjects = try file.wordSet("_QUESTION_SUBJECTS")
        sentenceClosers = Set(try file.scalars("_SENTENCE_CLOSERS"))
        let literals = try file.file("literals")
        questionMarks = try literals.words("question_marks")
        joinedWaw = try literals.scalars("joined_waw")
        anyWord = try literals.scalars("any")
        useWord = try literals.scalars("use")
        ofWord = try literals.scalars("of")
        ofOrderWord = try literals.scalars("of_order")
        twoTablets = try literals.scalars("two_tablets")
        statementJoiner = try literals.scalars("statement_joiner")
    }
}

/// A line-by-line port of `check_reply(read_back=True)` and what it reaches in
/// backend/ai/filters.py. The app has no model, so nothing else in that file is here. This one
/// path is, because it decides what a patient reads: `Scripted.summaryReply` falls to the plain
/// line when this fails.
public enum ReadBackCheck {
    private static var tables: FilterTables { RuleTables.shared.filters }
    private static var regex: RegexTables { RuleTables.shared.regex }

    private typealias Allowed = (doses: Set<Scalars>, drugs: Set<Scalars>)

    private static func isQuestion(_ sentence: Scalars) -> Bool {
        var end = sentence.count
        while end > 0, tables.sentenceClosers.contains(sentence[end - 1]) { end -= 1 }
        let trimmed = Array(sentence[..<end])
        return tables.questionMarks.contains(where: trimmed.endsWith)
    }

    private static func opensLikeQuestion(_ clause: Scalars) -> Bool {
        let tables = tables
        let words = TextRules.tokenise(clause).prefix(2).map(\.text)
        guard let first = words.first else { return false }
        if first == tables.anyWord { return true }
        return tables.questionOpeners.contains(first) && words.count == 2
            && tables.questionSubjects.contains(words[1])
    }

    /// Drop the interrogative parts of a sentence, keeping any statement in it.
    private static func statementPart(_ sentence: Scalars) -> Scalars {
        let question = isQuestion(sentence)
        let clauses = regex.clauseSplit.split(sentence)
        let kept = clauses.enumerated().filter { index, clause in
            !(question && index == clauses.count - 1) && !opensLikeQuestion(clause)
        }
        return kept.map(\.element).joined(with: tables.statementJoiner)
    }

    /// Every clause a question could hide in, with or without a question mark.
    private static func interrogativeClauses(_ sentence: Scalars) -> [Scalars] {
        let clauses = regex.clauseSplit.split(sentence)
        return isQuestion(sentence) ? clauses : clauses.filter(opensLikeQuestion)
    }

    /// Index of the first token that is not a lead-in such as "and" or "please".
    private static func firstWord(_ tokens: [Token]) -> Int {
        let leadIns = tables.leadIns
        return tokens.firstIndex { !leadIns.contains($0.text) } ?? tokens.count
    }

    private static func questionsCondition(_ tokens: [Token]) -> Bool {
        let tables = tables
        guard tables.diseaseTerms.contains(in: tokens) else { return false }
        let first = firstWord(tokens)
        for opener in tables.historyOpeners where TextRules.phraseStarts(tokens, opener).contains(first) {
            return tables.conditionTriggers.contains(in: Array(tokens[(first + opener.count)...]))
        }
        return true
    }

    private static func namesDiagnosisWord(_ tokens: [Token]) -> Bool {
        let refusals = tables.refusals
        return tables.diagnosisWords.matches(in: tokens).contains { match in
            !tokens[..<match.start].contains { refusals.contains($0.text) }
        }
    }

    /// A read-back may echo a disease with no trigger, so only a trigger makes it a diagnosis.
    private static func presentsDiagnosis(_ tokens: [Token]) -> Bool {
        let tables = tables
        if namesDiagnosisWord(tokens) { return true }
        guard tables.diseaseTerms.contains(in: tokens) else { return false }
        return tables.conditionTriggers.contains(in: tokens) || tables.secondPerson.contains(in: tokens)
    }

    /// True when each "and" part up to the next punctuation mark names a symptom.
    private static func namesSymptomThroughout(_ tokens: [Token]) -> Bool {
        var parts: [[Token]] = [[]]
        for token in tokens {
            if token.afterPunctuation { break }
            if token.startsClause, !parts[parts.count - 1].isEmpty { parts.append([]) }
            parts[parts.count - 1].append(token)
        }
        let symptoms = tables.symptoms
        return parts.allSatisfy { symptoms.contains(in: $0) }
    }

    private static func claimsCondition(_ tokens: [Token]) -> Bool {
        let tables = tables
        for match in tables.conditionOpeners.matches(in: tokens) {
            let rest = Array(tokens[(match.start + tables.conditionOpeners.phrases[match.phrase].count)...])
            if let first = rest.first, tables.reportingVerbs.contains(first.text) { continue }
            if !namesSymptomThroughout(rest) { return true }
        }
        return false
    }

    private static func drugsNamed(_ tokens: [Token]) -> Set<Scalars> {
        var named = Set<Scalars>()
        for drug in tables.drugs where drug.phrases.contains(in: tokens) { named.insert(drug.canonical) }
        return named
    }

    private static func drugWithoutTookWord(_ sentence: Scalars) -> Bool {
        let tables = tables
        for clause in regex.clauseSplit.split(sentence) {
            let tokens = TextRules.tokenise(clause)
            let earliest = tables.tookWords.matches(in: tokens).map(\.start).min() ?? tokens.count
            if tables.allDrugPhrases.matches(in: tokens).contains(where: { $0.start < earliest }) {
                return true
            }
        }
        return false
    }

    private static func givesAdvice(_ tokens: [Token]) -> Bool {
        let tables = tables
        if drugsNamed(tokens).isEmpty { return false }
        return tables.adviceTriggers.matches(in: tokens).contains { match in
            let phrase = tables.adviceTriggers.phrases[match.phrase]
            let follower = match.start + phrase.count
            let isNounUse =
                phrase == [tables.useWord] && follower < tokens.count
                && tokens[follower].text == tables.ofWord
            return !isNounUse
        }
    }

    /// True when the token at `index` opens a clause as an imperative. Attached waw is treated as
    /// "and", since it never appears as a token of its own.
    private static func isOrder(_ tokens: [Token], _ index: Int) -> Bool {
        let tables = tables
        let token = tokens[index]
        let joined =
            token.text.starts(with: tables.joinedWaw)
            && tables.imperatives.contains(Array(token.text.dropFirst(tables.joinedWaw.count)))
        if !tables.imperatives.contains(token.text), !joined { return false }
        let opens =
            joined || token.startsClause || (index > 0 && tables.leadIns.contains(tokens[index - 1].text))
        let following = tokens[(index + 1)...].prefix(2).map(\.text)
        let harmless = tables.harmlessOrders.contains(following) || following.first == tables.ofOrderWord
        return opens && !harmless
    }

    private static func ordersTreatment(_ tokens: [Token]) -> Bool {
        tokens.indices.contains { isOrder(tokens, $0) }
    }

    private static func questionOpensOnOrder(_ tokens: [Token]) -> Bool {
        let first = firstWord(tokens)
        return first < tokens.count && isOrder(tokens, first)
    }

    private static func doses(_ text: Scalars) -> Set<Scalars> {
        let tables = tables
        let regex = regex
        var doses = Set<Scalars>()
        for match in regex.dose.finditer(text) {
            if let quantity = regex.dose.captured(match, 0, in: text),
                let unit = regex.dose.captured(match, 1, in: text),
                let canonical = tables.unitCanonical[unit]
            {
                doses.insert(quantity + canonical)
            }
        }
        for match in regex.spelledDose.finditer(text) {
            if let word = regex.spelledDose.captured(match, 0, in: text),
                let unit = regex.spelledDose.captured(match, 1, in: text),
                let number = tables.numberWords[word], let canonical = tables.unitCanonical[unit]
            {
                doses.insert(number + canonical)
            }
        }
        if regex.arabicDualDose.search(text) != nil { doses.insert(tables.twoTablets) }
        return doses
    }

    private static func hasUnlistedDose(_ sentence: Scalars, _ allowed: [Allowed]) -> Bool {
        let doses = doses(sentence)
        if doses.isEmpty { return false }
        let named = drugsNamed(TextRules.tokenise(sentence))
        let allowedDrugs = allowed.reduce(into: Set<Scalars>()) { $0.formUnion($1.drugs) }
        if !named.subtracting(allowedDrugs).isEmpty { return true }
        for dose in doses {
            let holders = allowed.filter { $0.doses.contains(dose) }.map(\.drugs)
            if holders.isEmpty { return true }
            if !named.isEmpty, !holders.contains(where: { !$0.isDisjoint(with: named) }) { return true }
        }
        return false
    }

    private static func mentionsQueue(_ sentence: Scalars) -> Bool {
        let tables = tables
        let regex = regex
        if regex.ticket.search(sentence) != nil { return true }
        if tables.queueWords.contains(in: TextRules.tokenise(statementPart(sentence))) { return true }

        // A pain scale question may say "number" and "0 to 10". Only those words are excused.
        let body = isQuestion(sentence) ? regex.painScale.sub([0x20], in: sentence) : sentence
        let named = body != sentence ? statementPart(sentence) : sentence
        if tables.queueTerms.contains(in: TextRules.tokenise(named)) { return true }
        if regex.countWords.search(body) != nil, tables.placeWords.contains(in: TextRules.tokenise(body)) {
            return true
        }
        if regex.ordinalPlace.search(sentence) != nil { return true }

        let givesTime = regex.minutes.search(sentence) != nil || regex.hours.search(sentence) != nil
        return givesTime && tables.waitTerms.contains(in: TextRules.tokenise(sentence))
    }

    private static func allowedEntries(_ allowedMeds: [String]) -> [Allowed] {
        allowedMeds.map { med in
            let norm = TextRules.normalise(med)
            return (doses(norm), drugsNamed(TextRules.tokenise(norm)))
        }
    }

    private static func sharedReasons(_ sentence: Scalars, _ allowed: [Allowed]) -> Set<ReadBackReason> {
        var found = Set<ReadBackReason>()
        if hasUnlistedDose(sentence, allowed) { found.insert(.drugDose) }
        let statement = TextRules.tokenise(statementPart(sentence))
        if givesAdvice(statement) || ordersTreatment(statement) { found.insert(.treatmentAdvice) }
        if mentionsQueue(sentence) { found.insert(.queueNumber) }
        return found
    }

    /// Check the server's own summary. A statement may echo a disease the patient named, and a
    /// drug passes only after a took-word in its clause.
    public static func check(_ text: String, allowedMeds: [String] = []) -> ReadBackResult {
        check(text.scalars, allowedMeds: allowedMeds)
    }

    static func check(_ text: Scalars, allowedMeds: [String]) -> ReadBackResult {
        let tables = tables
        let allowed = allowedEntries(allowedMeds)
        let covered = allowed.reduce(into: Set<Scalars>()) { $0.formUnion($1.drugs) }
        var found = Set<ReadBackReason>()
        for sentence in TextRules.splitSentences(TextRules.normalise(text)) {
            found.formUnion(sharedReasons(sentence, allowed))
            let part = statementPart(sentence)
            let statement = TextRules.tokenise(part)
            let questions = interrogativeClauses(sentence).map { TextRules.tokenise($0) }
            if presentsDiagnosis(statement) || claimsCondition(statement)
                || tables.guessOpeners.contains(in: statement) || questions.contains(where: questionsCondition)
            {
                found.insert(.diagnosis)
            }
            if !drugsNamed(statement).subtracting(covered).isEmpty
                || questions.contains(where: questionOpensOnOrder)
            {
                found.insert(.treatmentAdvice)
            }
            if drugWithoutTookWord(part) { found.insert(.treatmentAdvice) }
        }
        let reasons = ReadBackReason.allCases.filter(found.contains)
        return ReadBackResult(ok: reasons.isEmpty, reasons: reasons)
    }
}
