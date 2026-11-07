import Foundation

/// Everything the Python source defines as data, loaded once from the engine.rules.*.json
/// resources. The file layouts are in ios/Tools/export/rules.py. Nothing in this folder retypes a
/// cue, a table or a line of wording.
struct RuleTables: Sendable {
    static let shared = RuleTables()

    let unicode: PythonUnicode
    let text: TextTables
    let redFlags: RedFlagTables
    let refill: RefillTables
    let simulated: SimulatedTables
    let filters: FilterTables
    let regex: RegexTables

    private init() {
        do {
            unicode = try PythonUnicode(file: RuleFile("unicode"))
            text = try TextTables(file: RuleFile("text"))
            redFlags = try RedFlagTables(file: RuleFile("redflags"))
            refill = try RefillTables(file: RuleFile("refill"))
            simulated = try SimulatedTables(file: RuleFile("simulated"))
            filters = try FilterTables(file: RuleFile("filters"))
            regex = try RegexTables(file: RuleFile("regex"))
        } catch {
            preconditionFailure("The engine's rule data does not load: \(error)")
        }
    }
}

enum RuleFileError: Error {
    case missing(String)
    case wrongShape(String)
}

/// One JSON object, read with the plain accessors the tables need. It exists only during loading.
struct RuleFile {
    let name: String
    private let object: [String: Any]

    init(_ name: String) throws {
        let file = "engine.rules.\(name)"
        guard let url = Bundle.module.url(forResource: file, withExtension: "json") else {
            throw RuleFileError.missing(file)
        }
        let value = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let object = value as? [String: Any] else { throw RuleFileError.wrongShape(file) }
        self.init(name: file, object: object)
    }

    private init(name: String, object: [String: Any]) {
        self.name = name
        self.object = object
    }

    private func value(_ key: String) throws -> Any {
        guard let value = object[key] else { throw RuleFileError.missing("\(name).\(key)") }
        return value
    }

    private func typed<T>(_ key: String) throws -> T {
        guard let value = try value(key) as? T else { throw RuleFileError.wrongShape("\(name).\(key)") }
        return value
    }

    func file(_ key: String) throws -> RuleFile {
        RuleFile(name: "\(name).\(key)", object: try typed(key))
    }

    func int(_ key: String) throws -> Int { try typed(key) }
    func double(_ key: String) throws -> Double { try typed(key) }
    func text(_ key: String) throws -> String { try typed(key) }
    func scalars(_ key: String) throws -> Scalars { try text(key).scalars }
    func strings(_ key: String) throws -> [String] { try typed(key) }
    func words(_ key: String) throws -> [Scalars] { try strings(key).map(\.scalars) }
    func wordSet(_ key: String) throws -> Set<Scalars> { Set(try words(key)) }
    func phrases(_ key: String) throws -> [[Scalars]] {
        let rows: [[String]] = try typed(key)
        return rows.map { $0.map(\.scalars) }
    }
    func phraseList(_ key: String) throws -> PhraseList { PhraseList(try phrases(key)) }
    func rows(_ key: String) throws -> [[Any]] { try typed(key) }
    func objects(_ key: String) throws -> [[String: Any]] { try typed(key) }

    /// A Python dict of str to str, which the exporter writes as ordered rows.
    func wordMap(_ key: String) throws -> [Scalars: Scalars] {
        let rows: [[String]] = try typed(key)
        var map: [Scalars: Scalars] = [:]
        for row in rows { map[row[0].scalars] = row[1].scalars }
        return map
    }

    /// A Python dict of str to a table of phrases, as ordered rows.
    func phraseRows(_ key: String) throws -> [(key: Scalars, phrases: [[Scalars]])] {
        try rows(key).map { row in
            guard let name = row[0] as? String, let phrases = row[1] as? [[String]] else {
                throw RuleFileError.wrongShape("\(self.name).\(key)")
            }
            return (name.scalars, phrases.map { $0.map(\.scalars) })
        }
    }

    /// Inclusive [first, last] code point rows.
    func ranges(_ key: String) throws -> [(UInt32, UInt32)] {
        let rows: [[Int]] = try typed(key)
        return rows.map { (UInt32($0[0]), UInt32($0[1])) }
    }

    /// A language to wording table such as OPENING: en and ar rows.
    func byLanguage(_ key: String) throws -> Worded {
        try Worded(try wordMap(key))
    }
}

/// One wording in each language.
struct Worded: Sendable {
    private let en: Scalars
    private let ar: Scalars

    init(_ rows: [Scalars: Scalars]) throws {
        guard let en = rows["en".scalars], let ar = rows["ar".scalars] else {
            throw RuleFileError.wrongShape("a row without en or ar")
        }
        self.en = en
        self.ar = ar
    }

    subscript(key: LanguageKey) -> Scalars {
        switch key {
        case .en: en
        case .ar: ar
        }
    }
}

/// `_key(lang)`: the only two wordings there are.
enum LanguageKey: Sendable {
    case en, ar

    init(_ language: Scalars) {
        self = language.starts(with: "ar".scalars) ? .ar : .en
    }

    var scalars: Scalars {
        switch self {
        case .en: "en".scalars
        case .ar: "ar".scalars
        }
    }
}

extension PythonUnicode {
    init(file: RuleFile) throws {
        let values = try file.rows("decimal_values")
        word = RangeTable(ranges: try file.ranges("word"))
        space = RangeTable(ranges: try file.ranges("space"))
        decimal = RangeTable(ranges: try file.ranges("decimal"))
        digit = RangeTable(ranges: try file.ranges("digit"))
        intakeStrip = RangeTable(ranges: try file.ranges("intake_strip"))
        decimalValues = try values.map { row in
            guard let first = row[0] as? Int, let last = row[1] as? Int, let value = row[2] as? Int else {
                throw RuleFileError.wrongShape("decimal_values")
            }
            return (UInt32(first), UInt32(last), UInt32(value))
        }
    }
}

struct TextTables: Sendable {
    let dropped: RangeTable
    let charMap: [UInt32: Scalars]
    let arabicLetter: RangeTable
    let lineBreaks: RangeTable
    let clausePunctuation: RangeTable
    let clauseWords: Set<Scalars>
    let proclitics: [Scalars]
    let negators: [[Scalars]]
    let negationExceptions: Set<Scalars>
    let englishAffirmations: Set<Scalars>
    let arabicAffirmations: Set<Scalars>
    let waw: Scalars
    let contractedProclitic: Scalars
    let article: Scalars

    init(file: RuleFile) throws {
        dropped = RangeTable(ranges: try file.ranges("_DROPPED"))
        var map: [UInt32: Scalars] = [:]
        for row in try file.rows("_CHAR_MAP") {
            guard let point = row[0] as? Int, let replacement = row[1] as? String else {
                throw RuleFileError.wrongShape("_CHAR_MAP")
            }
            map[UInt32(point)] = replacement.scalars
        }
        charMap = map
        arabicLetter = RangeTable(ranges: try file.ranges("_ARABIC_LETTER"))
        lineBreaks = RangeTable(ranges: try file.ranges("_LINE_BREAKS"))
        let punctuation = try file.words("_CLAUSE_PUNCTUATION").flatMap { $0 }
        clausePunctuation = RangeTable(ranges: punctuation.sorted().map { ($0, $0) })
        clauseWords = try file.wordSet("_CLAUSE_WORDS")
        proclitics = try file.words("_PROCLITICS")
        negators = try file.phrases("_NEGATORS")
        negationExceptions = try file.wordSet("_NEGATION_EXCEPTIONS")
        englishAffirmations = try file.wordSet("_ENGLISH_AFFIRMATIONS")
        arabicAffirmations = try file.wordSet("_ARABIC_AFFIRMATIONS")
        let literals = try file.file("literals")
        waw = try literals.scalars("waw")
        contractedProclitic = try literals.scalars("contracted_proclitic")
        article = try literals.scalars("article")
    }
}

struct RegexTables: Sendable {
    private let patterns: [Scalars: RuleRegex]
    let sentenceEnd: RuleRegex
    let outOfTen: RuleRegex
    let severityNumber: RuleRegex
    let counted: RuleRegex
    let dual: RuleRegex
    let single: RuleRegex
    let pointsInTime: [RuleRegex]
    /// `_COUNTED_ENGLISH`, which the code only ever calls fullmatch on.
    let countedEnglishWhole: RuleRegex
    let notThisNumber: RuleRegex
    let dose: RuleRegex
    let spelledDose: RuleRegex
    let arabicDualDose: RuleRegex
    let ticket: RuleRegex
    let ordinalPlace: RuleRegex
    let minutes: RuleRegex
    let hours: RuleRegex
    let countWords: RuleRegex
    let painScale: RuleRegex
    let clauseSplit: RuleRegex
    let patientVoiceWord: RuleRegex
    let latinLetter: RuleRegex

    init(file: RuleFile) throws {
        var byName: [Scalars: RuleRegex] = [:]
        var points: [RuleRegex] = []
        for row in try file.objects("patterns") {
            guard let name = row["name"] as? String, let icu = row["icu"] as? String,
                let options = row["options"] as? [String]
            else { throw RuleFileError.wrongShape("patterns") }
            let compiled = try RuleRegex(
                name: name, icu: icu, caseInsensitive: !options.isEmpty,
                value: (row["value"] as? String)?.scalars)
            byName[name.scalars] = compiled
            if name.scalars.starts(with: "simulated._POINTS_IN_TIME[".scalars) { points.append(compiled) }
        }
        func named(_ name: String) throws -> RuleRegex {
            guard let found = byName[name.scalars] else { throw RuleFileError.missing(name) }
            return found
        }
        patterns = byName
        pointsInTime = points
        sentenceEnd = try named("text._SENTENCE_END")
        outOfTen = try named("simulated._OUT_OF_TEN")
        severityNumber = try named("simulated._SEVERITY_NUMBER")
        counted = try named("simulated._COUNTED")
        dual = try named("simulated._DUAL")
        single = try named("simulated._SINGLE")
        countedEnglishWhole = try named("simulated._COUNTED_ENGLISH").anchored()
        notThisNumber = try named("simulated._NOT_THIS_NUMBER")
        dose = try named("filters._DOSE")
        spelledDose = try named("filters._SPELLED_DOSE")
        arabicDualDose = try named("filters._ARABIC_DUAL_DOSE")
        ticket = try named("filters._TICKET")
        ordinalPlace = try named("filters._ORDINAL_PLACE")
        minutes = try named("filters._MINUTES")
        hours = try named("filters._HOURS")
        countWords = try named("filters._COUNT")
        painScale = try named("filters._PAIN_SCALE")
        clauseSplit = try named("filters._CLAUSE_SPLIT")
        patientVoiceWord = try named("redflags._in_patient_voice")
        latinLetter = try named("simulated.detect_lang")
    }

    /// Any pattern by its exported name.
    func named(_ name: Scalars) -> RuleRegex? { patterns[name] }
}
