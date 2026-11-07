/// One scripted turn: a question, or the read-back with its intake.
public struct SimTurn: Sendable {
    public let reply: String
    public let slot: String?
    public let intake: IntakeRecord?
    public let language: String
}

struct SimulatedTables: Sendable {
    typealias Named = (name: Scalars, phrases: PhraseList)

    let opening: Worded
    let durationQuestion: Worded
    let severityQuestion: Worded
    let medicineQuestion: Worded
    let otherQuestion: Worded
    let painFollowUp: Worded
    let feverFollowUp: Worded
    let vomitingFollowUp: Worded
    let emergency: Worded
    let support: Worded
    let refill: Worded
    let summaryIntro: Worded
    let summaryCheck: Worded
    let summaryPlain: Worded
    let summarySeverity: Worded
    let summaryTook: Worded
    let summaryAnd: Worded
    let complaints: [Named]
    let complaintAr: [Scalars: Scalars]
    let painWords: PhraseList
    let serviceKeywords: [Named]
    let gulfMarkers: PhraseList
    let medicines: [Named]
    let notTaken: PhraseList
    let notADoseTaken: [[Scalars]]
    let noWords: Set<Scalars>
    let noPhrases: PhraseList
    let whereWords: PhraseList
    let slotHints: [Named]
    let numberWords: [Scalars: Int]
    let units: [Scalars: Scalars]
    let duals: [Scalars: Scalars]
    let arUnits: [Scalars: (one: Scalars, two: Scalars, many: Scalars)]
    let arPoints: [Scalars: Scalars]
    let correctionWords: Set<Scalars>
    let maxQuestions: Int
    let notAQuestion: Scalars
    let maxComplaint: Int
    let maxPatientWords: Int
    let maxSummary: Int
    let maxConcerns: Int
    let severityAsks: Int
    let services: Set<Scalars>
    let languages: Set<Scalars>
    let readBackJoiner: Worded
    let complaintJoiner: Worded
    let complaintSplit: Scalars
    let readBackEnd: Scalars
    let slotComplaint: Scalars
    let slotDuration: Scalars
    let slotSeverity: Scalars
    let slotFollowUp: Scalars
    let slotMedicine: Scalars
    let slotOther: Scalars
    let askFever: Scalars
    let askVomiting: Scalars
    let stomachPain: Scalars
    let diarrhoea: Scalars
    let dental: Scalars
    let languageEn: Scalars
    let languageGulf: Scalars
    let languageMsa: Scalars
    let taggedPrefix: Scalars
    let since: Scalars
    let complaintsJoiner: Scalars
    let locationJoiner: Scalars
    let defaultService: Scalars
    let confidenceMatched: Double
    let confidenceUnmatched: Double
    let nurseSeverityPrefix: Scalars
    let nurseSeveritySuffix: Scalars
    let nurseTook: Scalars
    let nurseMedicinesJoiner: Scalars
    let nurseJoiner: Scalars
    let nurseEnd: Scalars
    let refillFallback: Scalars
    let refillComplaintSuffix: Scalars
    let refillAsked: Scalars
    let refillService: Scalars
    let refillConfidence: Double

    init(file: RuleFile) throws {
        func named(_ key: String) throws -> [Named] {
            try file.phraseRows(key).map { ($0.key, PhraseList($0.phrases)) }
        }
        func nested(_ key: String) throws -> [Scalars: [Scalars: Scalars]] {
            var table: [Scalars: [Scalars: Scalars]] = [:]
            for row in try file.rows(key) {
                guard let name = row[0] as? String, let cells = row[1] as? [[String]] else {
                    throw RuleFileError.wrongShape(key)
                }
                var inner: [Scalars: Scalars] = [:]
                for cell in cells { inner[cell[0].scalars] = cell[1].scalars }
                table[name.scalars] = inner
            }
            return table
        }
        func worded(_ key: String) throws -> [Scalars: Worded] {
            try nested(key).mapValues { try Worded($0) }
        }

        func question(_ table: [Scalars: Worded], _ name: Scalars) throws -> Worded {
            guard let wording = table[name] else { throw RuleFileError.missing(name.string) }
            return wording
        }

        opening = try file.byLanguage("OPENING")
        emergency = try file.byLanguage("_EMERGENCY")
        support = try file.byLanguage("_SUPPORT")
        refill = try file.byLanguage("_REFILL")
        summaryIntro = try file.byLanguage("_SUMMARY_INTRO")
        summaryCheck = try file.byLanguage("_SUMMARY_CHECK")
        summaryPlain = try file.byLanguage("_SUMMARY_PLAIN")
        let labels = try nested("_SUMMARY_LABELS")
        func label(_ name: String) throws -> Worded {
            var rows: [Scalars: Scalars] = [:]
            for (language, cells) in labels { rows[language] = cells[name.scalars] }
            return try Worded(rows)
        }
        summarySeverity = try label("severity")
        summaryTook = try label("took")
        summaryAnd = try label("and")
        complaints = try named("_COMPLAINTS")
        complaintAr = try file.wordMap("_COMPLAINT_AR")
        painWords = try file.phraseList("_PAIN_WORDS")
        serviceKeywords = try named("_SERVICE_KEYWORDS")
        gulfMarkers = try file.phraseList("_GULF_MARKERS")
        medicines = try named("_MEDICINES")
        notTaken = try file.phraseList("_NOT_TAKEN")
        notADoseTaken = try file.phrases("_NOT_A_DOSE_TAKEN")
        noWords = try file.wordSet("_NO_WORDS")
        noPhrases = try file.phraseList("_NO_PHRASES")
        whereWords = try file.phraseList("_WHERE_WORDS")
        slotHints = try named("_SLOT_HINTS")
        var numbers: [Scalars: Int] = [:]
        for row in try file.rows("_NUMBER_WORDS") {
            guard let word = row[0] as? String, let value = row[1] as? Int else {
                throw RuleFileError.wrongShape("_NUMBER_WORDS")
            }
            numbers[word.scalars] = value
        }
        numberWords = numbers
        units = try file.wordMap("_UNITS")
        duals = try file.wordMap("_DUALS")
        var forms: [Scalars: (one: Scalars, two: Scalars, many: Scalars)] = [:]
        for row in try file.rows("_AR_UNITS") {
            guard let unit = row[0] as? String, let words = row[1] as? [String], words.count == 3 else {
                throw RuleFileError.wrongShape("_AR_UNITS")
            }
            forms[unit.scalars] = (words[0].scalars, words[1].scalars, words[2].scalars)
        }
        arUnits = forms
        arPoints = try file.wordMap("_AR_POINTS")
        correctionWords = try file.wordSet("_CORRECTION_WORDS")
        maxQuestions = try file.int("MAX_QUESTIONS")
        notAQuestion = try file.scalars("NOT_A_QUESTION")
        maxComplaint = try file.int("_MAX_COMPLAINT")
        maxPatientWords = try file.int("_MAX_PATIENT_WORDS")
        maxSummary = try file.int("_MAX_SUMMARY")
        maxConcerns = try file.int("_MAX_CONCERNS")
        severityAsks = try file.int("_SEVERITY_ASKS")
        let schema = try file.file("intake")
        services = try schema.wordSet("SERVICES")
        languages = try schema.wordSet("LANGUAGES")

        let literals = try file.file("literals")
        func byLanguage(_ key: String) throws -> Worded {
            let cells = try literals.file(key)
            return try Worded(["en".scalars: try cells.scalars("en"), "ar".scalars: try cells.scalars("ar")])
        }
        readBackJoiner = try byLanguage("read_back_joiner")
        complaintJoiner = try byLanguage("complaint_joiner")
        complaintSplit = try literals.scalars("complaint_split")
        readBackEnd = try literals.scalars("read_back_end")
        let slots = try literals.file("slots")
        slotComplaint = try slots.scalars("complaint")
        slotDuration = try slots.scalars("duration")
        slotSeverity = try slots.scalars("severity")
        slotFollowUp = try slots.scalars("followup")
        slotMedicine = try slots.scalars("medicine")
        slotOther = try slots.scalars("other")
        let questions = try worded("QUESTIONS")
        durationQuestion = try question(questions, slotDuration)
        severityQuestion = try question(questions, slotSeverity)
        medicineQuestion = try question(questions, slotMedicine)
        otherQuestion = try question(questions, slotOther)
        let followUp = try literals.file("follow_up")
        askFever = try followUp.scalars("fever")
        askVomiting = try followUp.scalars("vomiting")
        let followUps = try worded("FOLLOW_UPS")
        painFollowUp = try question(followUps, try followUp.scalars("pain"))
        feverFollowUp = try question(followUps, askFever)
        vomitingFollowUp = try question(followUps, askVomiting)
        stomachPain = try followUp.scalars("stomach_pain")
        diarrhoea = try followUp.scalars("diarrhoea")
        dental = try followUp.scalars("dental")
        let intakeLanguage = try literals.file("intake_language")
        languageEn = try intakeLanguage.scalars("en")
        languageGulf = try intakeLanguage.scalars("gulf")
        languageMsa = try intakeLanguage.scalars("msa")
        taggedPrefix = try literals.scalars("tagged_prefix")
        since = try literals.scalars("since")
        complaintsJoiner = try literals.scalars("complaints_joiner")
        locationJoiner = try literals.scalars("location_joiner")
        defaultService = try literals.scalars("default_service")
        let confidence = try literals.file("confidence")
        confidenceMatched = try confidence.double("matched")
        confidenceUnmatched = try confidence.double("unmatched")
        let nurse = try literals.file("nurse")
        nurseSeverityPrefix = try nurse.scalars("severity_prefix")
        nurseSeveritySuffix = try nurse.scalars("severity_suffix")
        nurseTook = try nurse.scalars("took")
        nurseMedicinesJoiner = try nurse.scalars("medicines_joiner")
        nurseJoiner = try nurse.scalars("joiner")
        nurseEnd = try nurse.scalars("end")
        let visit = try literals.file("refill_visit")
        refillFallback = try visit.scalars("fallback")
        refillComplaintSuffix = try visit.scalars("complaint_suffix")
        refillAsked = try visit.scalars("asked")
        refillService = try visit.scalars("service")
        refillConfidence = try visit.double("confidence")
    }
}

/// Python's unbounded `int`, as far as these rules need it: digits, with no leading zero, so
/// '99999999999999999999 days' cannot trap and '007 days' reads as 7.
struct WholeNumber: Sendable {
    /// Most significant first. Empty means zero.
    private let digits: [UInt32]

    /// `int(word)` for a word `str.isdigit` accepts, or nil for a digit-like character `int()`
    /// refuses. Python raises there, and this is the one place the port does not follow it.
    init?(digitsOf word: Scalars) {
        let unicode = RuleTables.shared.unicode
        var values: [UInt32] = []
        for point in word {
            guard let value = unicode.decimalValue(point) else { return nil }
            values.append(value)
        }
        digits = Array(values.drop(while: { $0 == 0 }))
    }

    init(_ value: Int) {
        var left = value
        var values: [UInt32] = []
        while left > 0 {
            values.insert(UInt32(left % 10), at: 0)
            left /= 10
        }
        digits = values
    }

    var isZero: Bool { digits.isEmpty }
    var isOne: Bool { digits == [1] }

    /// `str(number)`.
    var text: Scalars { digits.isEmpty ? [0x30] : digits.map { $0 + 0x30 } }

    /// `_in_range`: the value when it is from 0 to 10.
    var score: Int? {
        guard digits.count <= 2 else { return nil }
        let value = digits.reduce(0) { $0 * 10 + Int($1) }
        return value <= 10 ? value : nil
    }
}

/// A line-by-line port of backend/ai/simulated.py: the same 6-question flow, deterministic and
/// always labelled. `nextTurn` is a pure function of the history. Nothing here computes a queue
/// position, or invents a duration or a severity.
public enum Scripted {
    private static var tables: SimulatedTables { RuleTables.shared.simulated }
    private static var regex: RegexTables { RuleTables.shared.regex }
    private static var unicode: PythonUnicode { RuleTables.shared.unicode }
    private static let space: Scalars = [0x20]

    // MARK: Questions and language

    /// The opening line in a language.
    public static func opening(lang: String) -> String {
        tables.opening[LanguageKey(lang.scalars)].string
    }

    /// The slot that marks a stored assistant message that was not a question.
    public static var notAQuestion: String { tables.notAQuestion.string }

    /// Questions asked so far. A history that starts with the patient had the opening.
    public static func questionCount(_ history: [ChatMessage]) -> Int {
        questionCount(history.map(ChatLine.init))
    }

    static func questionCount(_ history: [ChatLine]) -> Int {
        let notAQuestion = tables.notAQuestion
        let asked = history.filter { $0.isAssistant && $0.slot != notAQuestion }.count
        let seeded = history.first?.isAssistant == true
        return seeded ? asked : asked + 1
    }

    /// Only a sentence switches language. Single words and digits keep the current one.
    public static func detectLang(_ text: String, current: String) -> String {
        detectLang(text.scalars, current: current.scalars).string
    }

    static func detectLang(_ text: Scalars, current: Scalars) -> Scalars {
        let words = unicode.split(text)
        if words.count < 2 { return current }
        let arabic = words.filter(TextRules.hasArabic).count
        let latin = words.filter { regex.latinLetter.search($0) != nil }.count
        if arabic == latin { return current }
        return arabic > latin ? LanguageKey.ar.scalars : LanguageKey.en.scalars
    }

    // MARK: Reading the patient's words

    private static func isLive(_ tokens: [Token], _ start: Int, cue: Scalars) -> Bool {
        TextRules.hasLeadingWaw(cue, tokens[start].text) || !TextRules.isNegated(tokens, cueStart: start)
    }

    private static func liveStarts(_ tokens: [Token], _ list: PhraseList) -> [Int] {
        list.matches(in: tokens)
            .filter { isLive(tokens, $0.start, cue: list.phrases[$0.phrase][0]) }
            .map(\.start)
    }

    /// Canonical English complaint words, in the order the patient said them.
    public static func findComplaints(_ text: String) -> [String] {
        findComplaints(text.scalars).map(\.string)
    }

    static func findComplaints(_ text: Scalars) -> [Scalars] {
        let tokens = TextRules.tokenise(text)
        var found: [(name: Scalars, start: Int, order: Int)] = []
        for (order, complaint) in tables.complaints.enumerated() {
            if let start = liveStarts(tokens, complaint.phrases).min() {
                found.append((complaint.name, start, order))
            }
        }
        // `order` keeps Python's stable sort over dict order for two complaints at one start.
        return found.sorted { ($0.start, $0.order) < ($1.start, $1.order) }.map(\.name)
    }

    /// Medicine names only. A dose in the sentence is never carried over.
    public static func parseMedicines(_ text: String) -> [String] {
        parseMedicines(text.scalars).map(\.string)
    }

    static func parseMedicines(_ text: Scalars) -> [Scalars] {
        let tables = tables
        let tokens = TextRules.tokenise(text)
        return tables.medicines.filter { medicine in
            medicine.phrases.matches(in: tokens).contains { match in
                !TextRules.isNegated(tokens, cueStart: match.start, extra: tables.notADoseTaken)
            }
        }.map(\.name)
    }

    private static func number(_ word: Scalars) -> WholeNumber? {
        if unicode.isDigit(word) { return WholeNumber(digitsOf: word) }
        return tables.numberWords[word].map { WholeNumber($0) }
    }

    private static func durationText(_ count: WholeNumber, _ unit: Scalars) -> Scalars {
        let text = count.text + space + unit
        return count.isOne ? text : text + [0x73]
    }

    /// Normalised English duration, or nil. `tagged` means it answers "since when?".
    public static func parseDuration(_ text: String, tagged: Bool = false) -> String? {
        parseDuration(text.scalars, tagged: tagged)?.string
    }

    static func parseDuration(_ text: Scalars, tagged: Bool = false) -> Scalars? {
        let tables = tables
        let regex = regex
        let norm = TextRules.normalise(text)
        for candidate in tagged ? [norm, tables.taggedPrefix + norm] : [norm] {
            if let counted = regex.counted.search(candidate),
                let word = regex.counted.captured(counted, 0, in: candidate),
                let count = number(word), !count.isZero,
                let name = regex.counted.captured(counted, 1, in: candidate),
                let unit = tables.units[name]
            {
                return durationText(count, unit)
            }
            if let dual = regex.dual.search(candidate),
                let name = regex.dual.captured(dual, 0, in: candidate), let unit = tables.duals[name]
            {
                return durationText(WholeNumber(2), unit)
            }
            if let single = regex.single.search(candidate),
                let name = regex.single.captured(single, 0, in: candidate)
                    ?? regex.single.captured(single, 1, in: candidate),
                let unit = tables.units[name]
            {
                return durationText(WholeNumber(1), unit)
            }
            for pattern in regex.pointsInTime where pattern.search(candidate) != nil {
                return pattern.value
            }
        }
        return nil
    }

    /// A 0-10 score. `loose` reads a number inside a sentence that answers the question.
    public static func parseSeverity(_ text: String, loose: Bool = false) -> Int? {
        parseSeverity(text.scalars, loose: loose)
    }

    static func parseSeverity(_ text: Scalars, loose: Bool = false) -> Int? {
        let tables = tables
        let regex = regex
        let norm = TextRules.normalise(text)
        if let explicit = regex.outOfTen.search(norm) {
            return regex.outOfTen.captured(explicit, 0, in: norm).flatMap(number)?.score
        }
        let tokens = TextRules.tokenise(norm)
        if !loose, tokens.count != 1 { return nil }
        if let digits = regex.severityNumber.search(norm) {
            let found = Array(norm[digits.start..<digits.end])
            return found.contains(0x2E) ? nil : WholeNumber(digitsOf: found)?.score
        }
        for token in tokens {
            if let value = tables.numberWords[token.text] { return value }
        }
        return nil
    }

    /// The score in a short correction at the read-back. "8, not 6" means 8, and "it is not 8"
    /// names no score.
    private static func correctedSeverity(_ text: Scalars) -> Int? {
        let spoken = TextRules.tokenise(text).map(\.text).joined(with: space)
        let words = unicode.split(regex.notThisNumber.sub(space, in: spoken))
        let numbers = words.filter { number($0) != nil }
        let others = Set(words.filter { number($0) == nil })
        guard numbers.count == 1, others.isSubset(of: tables.correctionWords) else { return nil }
        return number(numbers[0])?.score
    }

    private static func meansNo(_ tokens: [Token]) -> Bool {
        guard let first = tokens.first, tokens.count <= 3 else { return false }
        return tables.noWords.contains(first.text) || tables.noPhrases.contains(in: tokens)
    }

    // MARK: What the history says

    private struct Facts {
        var complaints: [Scalars] = []
        var duration: Scalars?
        var severity: Int?
        var medicines: [Scalars] = []
        var saidNoMedicine = false
        var concerns: Scalars?
        var location: Scalars?
        var asked: [Scalars: Int] = [:]

        mutating func add(complaints words: [Scalars]) {
            for word in words where !complaints.contains(word) { complaints.append(word) }
        }

        func timesAsked(_ slot: Scalars) -> Int { asked[slot, default: 0] }
    }

    private static func askedSlot(_ message: ChatLine) -> Scalars? {
        if let slot = message.slot, !slot.isEmpty {
            return slot == tables.notAQuestion ? nil : slot
        }
        let tokens = TextRules.tokenise(message.content)
        return tables.slotHints.first { $0.phrases.contains(in: tokens) }?.name
    }

    private static func absorb(
        _ facts: inout Facts, _ text: Scalars, slot: Scalars?, question: Scalars, atReadBack: Bool
    ) {
        let tables = tables
        let tokens = TextRules.tokenise(text)
        facts.add(complaints: findComplaints(text))

        let duration = parseDuration(text, tagged: slot == tables.slotDuration)
        if let duration { facts.duration = duration }

        let bareAllowed = (slot == nil || slot == tables.slotSeverity) && duration == nil
        var severity: Int?
        if bareAllowed {
            severity = parseSeverity(text, loose: slot == tables.slotSeverity)
        } else if tokens.count > 1 {
            severity = parseSeverity(text)
        }
        if severity == nil, atReadBack, duration == nil { severity = correctedSeverity(text) }
        if let severity { facts.severity = severity }

        for name in parseMedicines(text) where !facts.medicines.contains(name) {
            facts.medicines.append(name)
        }
        facts.saidNoMedicine = facts.saidNoMedicine || tables.notTaken.contains(in: tokens)

        if slot == tables.slotOther {
            facts.concerns = meansNo(tokens) ? nil : text.prefixed(tables.maxConcerns)
        } else if slot == tables.slotFollowUp {
            if RedFlags.meansYes(tokens) {
                facts.add(complaints: findComplaints(question))
            } else if !meansNo(tokens), tables.whereWords.contains(in: TextRules.tokenise(question)) {
                facts.location = text
            }
        }
    }

    private static func read(_ history: [ChatLine]) -> Facts {
        var facts = Facts()
        var slot: Scalars? = tables.slotComplaint
        var question: Scalars = []
        var atReadBack = false
        for message in history {
            if message.isAssistant {
                slot = askedSlot(message)
                question = message.content
                atReadBack = message.slot == tables.notAQuestion
                if let slot { facts.asked[slot, default: 0] += 1 }
            } else {
                absorb(&facts, message.content, slot: slot, question: question, atReadBack: atReadBack)
                slot = nil
                question = []
                atReadBack = false
            }
        }
        return facts
    }

    private static func userMessages(_ history: [ChatLine]) -> [Scalars] {
        history.filter { !$0.isAssistant }.map(\.content)
    }

    private static func service(_ history: [ChatLine]) -> Scalars? {
        let messages = userMessages(history).map { TextRules.tokenise($0) }
        return tables.serviceKeywords.first { keyword in
            messages.contains { !liveStarts($0, keyword.phrases).isEmpty }
        }?.name
    }

    /// Which follow-up to ask, or nil when the complaint already answers it.
    private static func followUp(_ facts: Facts, _ history: [ChatLine]) -> Worded? {
        let tables = tables
        if facts.timesAsked(tables.slotFollowUp) > 0 { return nil }
        if let keyword = service(history), keyword != tables.dental { return nil }
        let complaints = facts.complaints
        if complaints.isEmpty,
            userMessages(history).contains(where: { tables.painWords.contains(in: TextRules.tokenise($0)) })
        {
            return tables.painFollowUp
        }
        if complaints.contains(tables.stomachPain) || complaints.contains(tables.diarrhoea),
            !complaints.contains(tables.askVomiting)
        {
            return tables.vomitingFollowUp
        }
        return complaints.contains(tables.askFever) ? nil : tables.feverFollowUp
    }

    private static func nextQuestion(_ facts: Facts, _ history: [ChatLine]) -> (slot: Scalars, wording: Worded)? {
        let tables = tables
        if facts.duration == nil, facts.timesAsked(tables.slotDuration) == 0 {
            return (tables.slotDuration, tables.durationQuestion)
        }
        if facts.severity == nil, facts.timesAsked(tables.slotSeverity) < tables.severityAsks {
            return (tables.slotSeverity, tables.severityQuestion)
        }
        if let wording = followUp(facts, history) {
            return (tables.slotFollowUp, wording)
        }
        let medicineKnown =
            !facts.medicines.isEmpty || facts.saidNoMedicine || facts.timesAsked(tables.slotMedicine) > 0
        if !medicineKnown {
            return (tables.slotMedicine, tables.medicineQuestion)
        }
        if facts.timesAsked(tables.slotOther) == 0 {
            return (tables.slotOther, tables.otherQuestion)
        }
        return nil
    }

    private static func intakeLanguage(_ history: [ChatLine], _ key: LanguageKey) -> Scalars {
        let tables = tables
        if key == .en { return tables.languageEn }
        let gulf = userMessages(history).contains { tables.gulfMarkers.contains(in: TextRules.tokenise($0)) }
        return gulf ? tables.languageGulf : tables.languageMsa
    }

    // MARK: The intake

    /// Append the denial line, trimming the summary rather than losing the line.
    public static func addDenied(_ summary: String, denied: [String]) -> String {
        addDenied(summary.scalars, denied: denied.map(\.scalars)).string
    }

    static func addDenied(_ summary: Scalars, denied: [Scalars]) -> Scalars {
        let line = RedFlags.deniedText(denied, lang: LanguageKey.en.scalars)
        if line.isEmpty || summary.containsRun(line) { return summary }
        let limit = tables.maxSummary
        let room = max(limit - line.count - 2, 0)
        let kept = unicode.rstrip(summary.prefixed(room))
        return (kept + space + line + [0x2E]).prefixed(limit)
    }

    private static func complaintWithDuration(_ complaint: Scalars, _ duration: Scalars?) -> Scalars {
        guard let duration else { return complaint }
        return duration.starts(with: tables.since)
            ? complaint + space + duration
            : duration + space + complaint
    }

    private static func nurseSummary(
        _ patient: Patient, complaint: Scalars, duration: Scalars?, severity: Int?, medicines: [Scalars]
    ) -> Scalars {
        let tables = tables
        var parts: [Scalars] = [
            "\(patient.age)".scalars + patient.sex.scalars,
            complaintWithDuration(complaint, duration),
        ]
        if let severity {
            parts.append(
                tables.nurseSeverityPrefix + "\(severity)".scalars + tables.nurseSeveritySuffix)
        }
        if !medicines.isEmpty {
            parts.append(tables.nurseTook + medicines.joined(with: tables.nurseMedicinesJoiner))
        }
        return (parts.joined(with: tables.nurseJoiner) + tables.nurseEnd).prefixed(tables.maxSummary)
    }

    private static func buildIntake(
        _ history: [ChatLine], _ patient: Patient, denied: [Scalars], key: LanguageKey, facts: Facts
    ) throws -> IntakeRecord {
        let tables = tables
        let firstWords = userMessages(history)[0]
        var complaint: Scalars
        if !facts.complaints.isEmpty {
            complaint = facts.complaints.joined(with: tables.complaintsJoiner)
        } else if let location = facts.location, !location.isEmpty {
            complaint = firstWords + tables.locationJoiner + location
        } else {
            complaint = firstWords
        }
        complaint = complaint.prefixed(tables.maxComplaint)
        let keywordService = service(history)
        let matched = keywordService != nil || !facts.complaints.isEmpty
        let summary = nurseSummary(
            patient, complaint: complaint, duration: facts.duration, severity: facts.severity,
            medicines: facts.medicines)
        return try IntakeRecord.validate(
            IntakeDraft(
                language: intakeLanguage(history, key).string,
                chiefComplaint: complaint.string,
                chiefComplaintPatientWords: firstWords.prefixed(tables.maxPatientWords).string,
                duration: facts.duration?.string,
                severity0To10: facts.severity,
                associated: facts.complaints.dropFirst().map(\.string),
                selfMedication: facts.medicines.map(\.string),
                service: (keywordService ?? tables.defaultService).string,
                serviceConfidence: matched ? tables.confidenceMatched : tables.confidenceUnmatched,
                summaryForNurse: addDenied(summary, denied: denied).string,
                questionsAsked: min(questionCount(history), tables.maxQuestions),
                deniedRedFlags: denied.map(\.string),
                patientConcerns: facts.concerns?.string))
    }

    /// The next scripted turn. `history` includes the patient's latest message. It throws only
    /// when the chat cannot make a valid intake, where the Python raises as well.
    public static func nextTurn(
        history: [ChatMessage], patient: Patient, denied: [String], lang: String
    ) throws -> SimTurn {
        try nextTurn(
            history.map(ChatLine.init), patient, denied: denied.map(\.scalars), lang: lang.scalars)
    }

    static func nextTurn(
        _ history: [ChatLine], _ patient: Patient, denied: [Scalars], lang: Scalars
    ) throws -> SimTurn {
        let tables = tables
        let users = userMessages(history)
        let key = LanguageKey(users.last.map { detectLang($0, current: lang) } ?? lang)
        let language = key.scalars.string
        if users.isEmpty {
            return SimTurn(
                reply: tables.opening[key].string, slot: tables.slotComplaint.string, intake: nil,
                language: language)
        }
        let facts = read(history)
        if questionCount(history) < tables.maxQuestions, let question = nextQuestion(facts, history) {
            return SimTurn(
                reply: question.wording[key].string, slot: question.slot.string, intake: nil,
                language: language)
        }
        let intake = try buildIntake(history, patient, denied: denied, key: key, facts: facts)
        return SimTurn(
            reply: summaryReply(intake.readBackFacts, key: key).string, slot: nil, intake: intake,
            language: language)
    }

    /// "I still want a visit": a GP intake for a patient the refill line would have served.
    public static func gpIntakeAfterRefill(
        history: [ChatMessage], patient: Patient, medicine: String, denied: [String], lang: String
    ) throws -> IntakeRecord {
        let tables = tables
        let lines = history.map(ChatLine.init)
        let facts = read(lines)
        let medicineName = medicine.scalars
        let name = unicode.split(medicineName).first ?? tables.refillFallback
        let complaint = name + tables.refillComplaintSuffix
        let firstWords = userMessages(lines).first ?? complaint
        let summary = nurseSummary(
            patient, complaint: complaint + tables.refillAsked, duration: nil, severity: nil, medicines: [])
        let deniedWords = denied.map(\.scalars)
        return try IntakeRecord.validate(
            IntakeDraft(
                language: intakeLanguage(lines, LanguageKey(lang.scalars)).string,
                chiefComplaint: complaint.string,
                chiefComplaintPatientWords: firstWords.prefixed(tables.maxPatientWords).string,
                duration: facts.duration?.string,
                severity0To10: facts.severity,
                associated: facts.complaints.map(\.string),
                selfMedication: facts.medicines.map(\.string),
                service: tables.refillService.string,
                serviceConfidence: tables.refillConfidence,
                summaryForNurse: addDenied(summary, denied: deniedWords).string,
                refillRequest: medicineName.isEmpty ? nil : medicine,
                questionsAsked: min(questionCount(lines), tables.maxQuestions),
                deniedRedFlags: denied,
                patientConcerns: facts.concerns?.string))
    }

    // MARK: The read-back

    private static func arabicDuration(_ duration: Scalars) -> Scalars {
        let tables = tables
        let pattern = regex.countedEnglishWhole
        if let point = tables.arPoints[duration] { return point }
        guard let counted = pattern.search(duration),
            let digits = pattern.captured(counted, 0, in: duration),
            let unit = pattern.captured(counted, 1, in: duration),
            let forms = tables.arUnits[unit], let count = WholeNumber(digitsOf: digits)
        else { return duration }
        if count.isOne { return forms.one }
        return count.score == 2 ? forms.two : count.text + space + forms.many
    }

    private static func arabicDrug(_ canonical: Scalars) -> Scalars {
        let forms = RuleTables.shared.filters.drugNames[canonical] ?? []
        return forms.first(where: TextRules.hasArabic) ?? canonical
    }

    /// Our own fixed complaint words when they fit, else the patient's own words.
    private static func readBackComplaint(_ facts: ReadBackFacts, key: LanguageKey) -> Scalars {
        let tables = tables
        let words = facts.chiefComplaint.scalars.split(on: tables.complaintSplit)
        let arabic = words.compactMap { tables.complaintAr[$0] }
        guard arabic.count == words.count else {
            return facts.chiefComplaintPatientWords.scalars.prefixed(tables.maxComplaint)
        }
        return (key == .ar ? arabic : words).joined(with: tables.complaintJoiner[key])
    }

    /// Rendered from fixed parts. The nurse's summary is never read.
    private static func readBack(_ facts: ReadBackFacts, key: LanguageKey) -> Scalars {
        let tables = tables
        var parts = [readBackComplaint(facts, key: key)]
        if let duration = parseDuration(facts.duration?.scalars ?? []) {
            parts.append(key == .ar ? arabicDuration(duration) : duration)
        }
        if let severity = facts.severity0To10 {
            parts.append(tables.summarySeverity[key].filled("{}".scalars, with: "\(severity)".scalars))
        }
        let medicines = facts.selfMedication.map(\.scalars)
        if !medicines.isEmpty {
            let names = key == .ar ? medicines.map(arabicDrug) : medicines
            parts.append(tables.summaryTook[key] + names.joined(with: tables.summaryAnd[key]))
        }
        let summary = parts.joined(with: tables.readBackJoiner[key]) + tables.readBackEnd
        let denied = RedFlags.deniedText(facts.deniedRedFlags.map(\.scalars), lang: key.scalars)
        return denied.isEmpty ? summary : summary + space + denied + tables.readBackEnd
    }

    /// The summary shown back to the patient, or a plain line if it would fail the filter. The
    /// patient's own medicines are allowed by name. Any other drug, a dose, or an order still
    /// fails and gives the plain line.
    public static func summaryReply(_ facts: ReadBackFacts, lang: String) -> String {
        summaryReply(facts, key: LanguageKey(lang.scalars)).string
    }

    static func summaryReply(_ facts: ReadBackFacts, key: LanguageKey) -> Scalars {
        let tables = tables
        let reply =
            tables.summaryIntro[key] + space + readBack(facts, key: key) + space + tables.summaryCheck[key]
        return ReadBackCheck.check(reply, allowedMeds: facts.selfMedication).ok ? reply : tables.summaryPlain[key]
    }

    public static func emergencyReply(lang: String, selfHarm: Bool) -> String {
        let key = LanguageKey(lang.scalars)
        return (selfHarm ? tables.emergency[key] + space + tables.support[key] : tables.emergency[key]).string
    }

    public static func refillReply(medicine: String, lang: String) -> String {
        tables.refill[LanguageKey(lang.scalars)]
            .filled("{medicine}".scalars, with: medicine.scalars).string
    }
}
