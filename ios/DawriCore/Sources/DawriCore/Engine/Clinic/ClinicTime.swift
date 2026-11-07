import Foundation

/// Port of backend/timeutil.py. The working day is Doha's fixed +03:00, never the device zone,
/// and every calculation is whole microseconds so nothing depends on a calendar.
public enum ClinicTime {
    private static let dohaOffset: Int64 = 3 * 3_600 * 1_000_000
    private static let microsPerDay: Int64 = 86_400 * 1_000_000

    /// `iso()`: UTC with fixed-width microseconds, so lexical order is time order.
    public static func iso(_ date: Date) -> String {
        Timestamp.string(from: date)
    }

    /// `parse()`: any ISO stamp `datetime.fromisoformat` takes here. No offset means UTC.
    public static func parse(_ text: String) -> Date? {
        microseconds(in: text).map(date(microseconds:))
    }

    /// `doha_day()`.
    public static func dohaDay(_ date: Date) -> String {
        let shifted = microseconds(of: date) + dohaOffset
        var days = shifted / microsPerDay
        if shifted % microsPerDay < 0 { days -= 1 }
        let (year, month, day) = civil(fromDays: days)
        return "\(pad(year, 4))-\(pad(month, 2))-\(pad(day, 2))"
    }

    /// `age_on()` on an instant, which reads the Doha date of it.
    public static func ageOn(dob: String, at date: Date) -> Int {
        ageOn(dob: dob, day: dohaDay(date))
    }

    /// `age_on()` on a plain date, which is taken as that date.
    public static func ageOn(dob: String, day: String) -> Int {
        guard let born = calendarDate(dob), let today = calendarDate(day) else {
            preconditionFailure("Not an ISO date: \(dob), \(day)")
        }
        let beforeBirthday = (today.month, today.day) < (born.month, born.day)
        return today.year - born.year - (beforeBirthday ? 1 : 0)
    }

    public static func date(microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
    }

    public static func microseconds(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1_000_000).rounded())
    }

    /// A stored stamp, which is always one this file wrote.
    static func storedMicroseconds(_ stamp: String) -> Int64 {
        guard let found = microseconds(in: stamp) else {
            preconditionFailure("Not a stored stamp: \(stamp)")
        }
        return found
    }

    /// `YYYY-MM-DD`, optionally `THH:MM:SS`, `.ffffff` and `Z` or `+HH:MM`.
    private static func microseconds(in text: String) -> Int64? {
        let bytes = Array(text.utf8)
        guard let day = calendarDate(bytes) else { return nil }
        var total = days(year: day.year, month: day.month, day: day.day) * microsPerDay
        guard bytes.count > 10 else { return bytes.count == 10 ? total : nil }

        guard bytes[10] == UInt8(ascii: "T") || bytes[10] == UInt8(ascii: " "),
              bytes.count >= 19, bytes[13] == UInt8(ascii: ":"), bytes[16] == UInt8(ascii: ":"),
              let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2),
              let second = number(bytes, 17, 2), hour < 24, minute < 60, second < 60
        else { return nil }
        total += Int64(hour * 3_600 + minute * 60 + second) * 1_000_000

        var index = 19
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            var fraction: Int64 = 0
            var digits = 0
            while index < bytes.count, let digit = digit(bytes[index]) {
                if digits < 6 {
                    fraction = fraction * 10 + Int64(digit)
                    digits += 1
                }
                index += 1
            }
            guard digits > 0 else { return nil }
            for _ in digits..<6 { fraction *= 10 }
            total += fraction
        }

        guard index < bytes.count else { return total }
        if bytes[index] == UInt8(ascii: "Z"), index + 1 == bytes.count { return total }
        let sign: Int64
        switch bytes[index] {
        case UInt8(ascii: "+"): sign = 1
        case UInt8(ascii: "-"): sign = -1
        default: return nil
        }
        guard bytes.count == index + 6, bytes[index + 3] == UInt8(ascii: ":"),
              let hours = number(bytes, index + 1, 2), let minutes = number(bytes, index + 4, 2)
        else { return nil }
        return total - sign * Int64(hours * 3_600 + minutes * 60) * 1_000_000
    }

    private static func calendarDate(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let bytes = Array(text.utf8)
        return bytes.count == 10 ? calendarDate(bytes) : nil
    }

    private static func calendarDate(_ bytes: [UInt8]) -> (year: Int, month: Int, day: Int)? {
        guard bytes.count >= 10, bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              let year = number(bytes, 0, 4), let month = number(bytes, 5, 2),
              let day = number(bytes, 8, 2), (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return (year, month, day)
    }

    private static func number(_ bytes: [UInt8], _ start: Int, _ width: Int) -> Int? {
        var value = 0
        for byte in bytes[start..<(start + width)] {
            guard let digit = digit(byte) else { return nil }
            value = value * 10 + digit
        }
        return value
    }

    private static func digit(_ byte: UInt8) -> Int? {
        (0x30...0x39).contains(byte) ? Int(byte) - 0x30 : nil
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(value)
        return String(repeating: "0", count: max(width - digits.count, 0)) + digits
    }

    /// Days since 1970-01-01 in the proleptic Gregorian calendar.
    private static func days(year: Int, month: Int, day: Int) -> Int64 {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return Int64(era) * 146_097 + Int64(dayOfEra) - 719_468
    }

    private static func civil(fromDays days: Int64) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra =
            (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = yearOfEra + era * 400 + (month <= 2 ? 1 : 0)
        return (Int(year), Int(month), Int(day))
    }
}
