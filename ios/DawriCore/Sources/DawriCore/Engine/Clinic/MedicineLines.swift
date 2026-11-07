import Foundation

/// `days` is an integer on a stored prescription. Text and decimals only come from a caller who
/// passes them, and Python prints those as written.
public enum MedicineDays: Sendable, Equatable {
    case whole(Int)
    case text(String)
    case decimal(Double)

    fileprivate var isOne: Bool { isWhole(1) }
    fileprivate var isTwo: Bool { isWhole(2) }

    private func isWhole(_ number: Int) -> Bool {
        switch self {
        case .whole(let value): value == number
        case .decimal(let value): value == Double(number)
        case .text: false
        }
    }

    fileprivate var shown: String {
        switch self {
        case .whole(let value): String(value)
        case .text(let value): value
        case .decimal(let value): String(value)
        }
    }
}

public struct MedicineItem: Sendable, Equatable {
    public var drug: String?
    public var dose: String?
    public var frequency: String?
    public var days: MedicineDays?
    public var notes: String?

    public init(
        drug: String? = nil, dose: String? = nil, frequency: String? = nil,
        days: MedicineDays? = nil, notes: String? = nil
    ) {
        self.drug = drug
        self.dose = dose
        self.frequency = frequency
        self.days = days
        self.notes = notes
    }
}

/// Port of backend/ai/medicines.py: plain-language medicine lines, deterministic templates
/// from the prescription fields. Every number comes from those fields.
public enum MedicineLines {
    private static var medicines: ClinicData.Text.Medicines { ClinicData.bundled.text.medicines }
    private static var templates: ClinicData.Text.Templates { ClinicData.bundled.text.templates }

    /// `_DOSE_UNIT`, read from the exported pattern rather than written again here.
    private static let doseUnit: NSRegularExpression = {
        struct File: Decodable {
            struct Pattern: Decodable {
                let name: String
                let icu: String
                let options: [String]
            }

            let patterns: [Pattern]
        }
        do {
            let data = try ClinicData.resource("engine.rules.regex")
            let file = try JSONDecoder().decode(File.self, from: data)
            guard let pattern = file.patterns.first(where: { $0.name == "medicines._DOSE_UNIT" })
            else { preconditionFailure("medicines._DOSE_UNIT is not in engine.rules.regex.json") }
            return try NSRegularExpression(
                pattern: pattern.icu,
                options: pattern.options.contains("caseInsensitive") ? [.caseInsensitive] : [])
        } catch {
            preconditionFailure("Invalid medicines._DOSE_UNIT: \(error)")
        }
    }()

    private static func text(_ value: String?) -> String {
        value.map(ClinicText.strip) ?? ""
    }

    /// A string outside the table is copied as written, never rewritten.
    private static func frequency(_ value: String, _ table: ClinicTable) -> String {
        table.value(for: ClinicText.lower(value)) ?? value
    }

    private static func doseAr(_ dose: String) -> String {
        let whole = dose as NSString
        var result = ""
        var cursor = 0
        for match in doseUnit.matches(in: dose, range: NSRange(location: 0, length: whole.length)) {
            result += whole.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            let digit = whole.substring(with: match.range(at: 1))
            let unit = whole.substring(with: match.range(at: 2))
            result += "\(digit) \(medicines.unitAr.value(for: ClinicText.lower(unit)) ?? unit)"
            cursor = match.range.location + match.range.length
        }
        return result + whole.substring(from: cursor)
    }

    private static func daysEn(_ days: MedicineDays) -> String {
        let table = templates.medicineDays
        return days.isOne ? table.enOne : ClinicText.fill(table.enMany, ["days": days.shown])
    }

    private static func daysAr(_ days: MedicineDays) -> String {
        let table = templates.medicineDays
        if days.isOne { return table.arOne }
        if days.isTwo { return table.arTwo }
        if case .whole(let value) = days, value >= table.arManyFrom {
            return ClinicText.fill(table.arMany, ["days": days.shown])
        }
        return ClinicText.fill(table.arFew, ["days": days.shown])
    }

    /// The name with its form in brackets, unless the name already says it.
    private static func label(_ name: String, form: String) -> String {
        if form.isEmpty || ClinicText.contains(ClinicText.lower(name), ClinicText.lower(form)) {
            return name
        }
        return "\(name) (\(form))"
    }

    private static func nameEn(_ item: MedicineItem, _ drug: DrugRecord?) -> String {
        let name = text(drug?.nameEn)
        return name.isEmpty ? text(item.drug) : ClinicText.capitalisedFirst(name)
    }

    private static func nameAr(_ item: MedicineItem, _ drug: DrugRecord?) -> String {
        let name = text(drug?.nameAr)
        return name.isEmpty ? text(item.drug) : name
    }

    private static func isArabic(_ lang: String) -> Bool {
        ClinicText.hasPrefix(lang, "ar")
    }

    private static func displayName(_ item: MedicineItem, lang: String, _ drug: DrugRecord?) -> String {
        isArabic(lang) ? nameAr(item, drug) : nameEn(item, drug)
    }

    /// What stands before the dose in a language's line template, between `{name}: ` and
    /// `{dose}`.
    private static func dosePrefix(_ template: String) -> String {
        guard let start = template.range(of: "{name}: "),
              let end = template.range(of: "{dose}")
        else { preconditionFailure("The medicine line template has changed shape: \(template)") }
        return String(template[start.upperBound..<end.lowerBound])
    }

    private static func line(label: String, parts: [String], joiner: String, notes: String) -> String {
        let line = parts.isEmpty
            ? ClinicText.fill(templates.medicineLine.bare, ["name": label])
            : "\(label): \(parts.joined(separator: joiner))."
        return notes.isEmpty ? line : "\(line) \(notes)"
    }

    public static func plainLine(_ item: MedicineItem, lang: String, drug: DrugRecord? = nil) -> String {
        let form = text(drug?.form)
        let dose = text(item.dose)
        let frequencyText = text(item.frequency)
        let notes = text(item.notes)
        let name = displayName(item, lang: lang, drug)
        let shape = templates.medicineLine

        var parts: [String] = []
        if isArabic(lang) {
            if !dose.isEmpty { parts.append(dosePrefix(shape.ar) + doseAr(dose)) }
            if !frequencyText.isEmpty {
                parts.append(frequency(frequencyText, medicines.frequencyAr))
            }
            if let days = item.days { parts.append(daysAr(days)) }
            let shownForm = medicines.formAr.value(for: ClinicText.lower(form)) ?? form
            return line(
                label: label(name, form: shownForm), parts: parts, joiner: shape.joiner.ar,
                notes: notes)
        }
        if !dose.isEmpty { parts.append(dosePrefix(shape.en) + dose) }
        if !frequencyText.isEmpty { parts.append(frequency(frequencyText, medicines.frequencyEn)) }
        if let days = item.days { parts.append(daysEn(days)) }
        return line(label: label(name, form: form), parts: parts, joiner: shape.joiner.en, notes: notes)
    }

    /// `lower()` in SQLite touches ASCII only.
    private static func sqliteLower(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            let lowered = (0x41...0x5A).contains(scalar.value)
                ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
            result.append(lowered)
        }
        return String(result)
    }

    /// `_find_drug`: the stored value may be the drug id or its English name.
    private static func findDrug(_ state: ClinicState, _ value: String) -> DrugRecord? {
        let lowered = sqliteLower(value)
        return state.drugs.first {
            ClinicText.same($0.id, value) || ClinicText.same(sqliteLower($0.nameEn), lowered)
        }
    }

    /// `for_visit`: this visit's prescription as lines in one language.
    public static func forVisit(_ state: ClinicState, visitId: String, lang: String) -> [MedicineLine] {
        state.prescriptions.filter { $0.visitId == visitId }.map { row in
            let item = MedicineItem(
                drug: row.drug, dose: row.dose, frequency: row.frequency,
                days: row.days.map(MedicineDays.whole), notes: row.notes)
            let drug = findDrug(state, text(row.drug))
            return MedicineLine(
                drug: row.drug, name: displayName(item, lang: lang, drug),
                line: plainLine(item, lang: lang, drug: drug))
        }
    }
}
