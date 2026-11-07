import Foundation

/// The backend's timestamps stay `String` in the models. This reads and writes that format:
/// ISO with fixed microseconds and an offset, `2026-11-07T09:00:00.901593+00:00`, from
/// `iso()` in backend/timeutil.py. Plain `ISO8601DateFormatter` does not parse it.
public enum Timestamp {
    public static func date(from text: String) -> Date? {
        let pattern = #/(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})\.(\d{6})([+-])(\d{2}):(\d{2})/#
        guard let match = try? pattern.wholeMatch(in: text),
              let year = Int(match.output.1), let month = Int(match.output.2),
              let day = Int(match.output.3), let hour = Int(match.output.4),
              let minute = Int(match.output.5), let second = Int(match.output.6),
              let micros = Int(match.output.7),
              let offsetHours = Int(match.output.9), let offsetMinutes = Int(match.output.10)
        else { return nil }

        let parts = DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard parts.isValidDate(in: utcCalendar), let whole = utcCalendar.date(from: parts) else {
            return nil
        }
        let offset = (offsetHours * 3600 + offsetMinutes * 60) * (match.output.8 == "-" ? -1 : 1)
        return whole.addingTimeInterval(Double(micros) / 1_000_000 - Double(offset))
    }

    public static func string(from date: Date) -> String {
        let seconds = date.timeIntervalSince1970.rounded(.down)
        let micros = Int(((date.timeIntervalSince1970 - seconds) * 1_000_000).rounded())
        let whole = Date(timeIntervalSince1970: seconds + (micros == 1_000_000 ? 1 : 0))
        let parts = utcCalendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: whole)
        func pad(_ value: Int?, _ width: Int) -> String {
            let digits = String(value ?? 0)
            return String(repeating: "0", count: max(width - digits.count, 0)) + digits
        }
        return "\(pad(parts.year, 4))-\(pad(parts.month, 2))-\(pad(parts.day, 2))"
            + "T\(pad(parts.hour, 2)):\(pad(parts.minute, 2)):\(pad(parts.second, 2))"
            + ".\(pad(micros == 1_000_000 ? 0 : micros, 6))+00:00"
    }

    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return calendar
    }()
}
