import Foundation

/// The ports of frontend/src/lib/format.ts.
public func nameOf(_ who: some NamedPerson, lang: Lang) -> String {
    lang == .ar ? who.fullNameAr : who.fullNameEn
}

public func centreName(_ centre: some NamedCentre, lang: Lang) -> String {
    lang == .ar ? centre.nameAr : centre.nameEn
}

/// Latin digits in both languages, so dates match the numbers on tickets. Doha's day and the
/// Gregorian calendar, whatever the phone is set to. A value that is not a backend timestamp
/// comes back as stored rather than failing a screen.
public func formatDate(_ iso: String, lang: Lang) -> String {
    guard let date = Timestamp.date(from: iso) else { return iso }
    let identifier = lang == .ar ? "ar_QA@numbers=latn;calendar=gregorian" : "en_GB"
    // A fixed pattern, because the system's Arabic pattern adds a comma the web does not have.
    let style = Date.VerbatimFormatStyle(
        format: "\(day: .defaultDigits) \(month: .abbreviated) \(year: .defaultDigits)",
        locale: Locale(identifier: identifier),
        timeZone: TimeZone(identifier: "Asia/Qatar") ?? TimeZone(secondsFromGMT: 3 * 3600) ?? .gmt,
        calendar: Calendar(identifier: .gregorian))
    return style.format(date)
}
