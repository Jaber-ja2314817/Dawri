/// Text as Python's `str` holds it: one element per code point.
///
/// All rule text is held in this form. Swift's `String` compares and hashes by canonical
/// equivalence and treats "\r\n" as one `Character`, so `String` is only ever the way in and out.
/// An array of `UInt32` compares element by element, which is exactly what Python's `==`, `in`
/// and dict keys do, and it is `Hashable` for free. Slices and lengths count code points.
typealias Scalars = [UInt32]

extension String {
    var scalars: Scalars { unicodeScalars.map(\.value) }
}

extension [UInt32] {
    var string: String {
        var view = String.UnicodeScalarView()
        for point in self {
            if let scalar = Unicode.Scalar(point) { view.append(scalar) }
        }
        return String(view)
    }

    /// `text[:limit]`.
    func prefixed(_ limit: Int) -> Scalars { Array(prefix(limit)) }

    func endsWith(_ suffix: Scalars) -> Bool {
        count >= suffix.count && self[(count - suffix.count)...].elementsEqual(suffix)
    }

    /// `needle in text`.
    func containsRun(_ needle: Scalars) -> Bool {
        guard needle.count <= count else { return false }
        if needle.isEmpty { return true }
        return (0...(count - needle.count)).contains { start in
            self[start..<(start + needle.count)].elementsEqual(needle)
        }
    }

    /// `text.split(separator)` with a literal separator, as Python scans it: left to right, not
    /// overlapping.
    func split(on separator: Scalars) -> [Scalars] {
        guard !separator.isEmpty else { return [self] }
        var parts: [Scalars] = []
        var start = 0
        var index = 0
        while index + separator.count <= count {
            if self[index..<(index + separator.count)].elementsEqual(separator) {
                parts.append(Array(self[start..<index]))
                index += separator.count
                start = index
            } else {
                index += 1
            }
        }
        parts.append(Array(self[start...]))
        return parts
    }

    /// `template.format(value)` for a template with one `{}` or `{name}` placeholder.
    func filled(_ placeholder: Scalars, with value: Scalars) -> Scalars {
        Array(split(on: placeholder).joined(separator: value))
    }
}

extension [Scalars] {
    /// `separator.join(words)`.
    func joined(with separator: Scalars) -> Scalars { Scalars(joined(separator: separator)) }
}

/// Python's `dict.fromkeys(items)`: the first time each item appears, in order.
func uniqued(_ items: some Sequence<Scalars>) -> [Scalars] {
    var seen = Set<Scalars>()
    return items.filter { seen.insert($0).inserted }
}

/// `sorted(items)`: Python orders strings by code point, which `String` does not.
func pythonSorted(_ items: some Sequence<Scalars>) -> [Scalars] {
    items.sorted { $0.lexicographicallyPrecedes($1) }
}

/// A set of code points read from inclusive [first, last] ranges, by binary search.
struct RangeTable: Sendable {
    private let lows: [UInt32]
    private let highs: [UInt32]
    private let ascii: [Bool]

    init(ranges: [(UInt32, UInt32)]) {
        lows = ranges.map(\.0)
        highs = ranges.map(\.1)
        ascii = (0..<128).map { point in ranges.contains { $0.0 <= point && point <= $0.1 } }
    }

    func contains(_ point: UInt32) -> Bool {
        if point < 128 { return ascii[Int(point)] }
        var low = 0
        var high = lows.count
        while low < high {
            let middle = (low + high) / 2
            if point > highs[middle] {
                low = middle + 1
            } else {
                high = middle
            }
        }
        return low < lows.count && point >= lows[low]
    }
}

/// Python's character classes, from engine.rules.unicode.json. Nothing here asks Swift or ICU.
struct PythonUnicode: Sendable {
    let word: RangeTable
    let space: RangeTable
    let decimal: RangeTable
    let digit: RangeTable
    let intakeStrip: RangeTable
    /// first, last, and the digit value of first.
    let decimalValues: [(first: UInt32, last: UInt32, value: UInt32)]

    /// `unicodedata.decimal`, or nil for anything `int()` would refuse.
    func decimalValue(_ point: UInt32) -> UInt32? {
        var low = 0
        var high = decimalValues.count
        while low < high {
            let middle = (low + high) / 2
            if point > decimalValues[middle].last {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < decimalValues.count, point >= decimalValues[low].first else { return nil }
        return decimalValues[low].value + (point - decimalValues[low].first)
    }

    /// `str.isdigit`.
    func isDigit(_ text: Scalars) -> Bool {
        !text.isEmpty && text.allSatisfy(digit.contains)
    }

    /// `str.strip()`.
    func strip(_ text: Scalars) -> Scalars { trim(text, leading: true, in: space) }

    /// `str.rstrip()`.
    func rstrip(_ text: Scalars) -> Scalars { trim(text, leading: false, in: space) }

    /// What pydantic strips, which is not quite the same set as `strip`.
    func stripIntake(_ text: Scalars) -> Scalars { trim(text, leading: true, in: intakeStrip) }

    private func trim(_ text: Scalars, leading: Bool, in table: RangeTable) -> Scalars {
        var start = 0
        var end = text.count
        if leading {
            while start < end, table.contains(text[start]) { start += 1 }
        }
        while end > start, table.contains(text[end - 1]) { end -= 1 }
        return Array(text[start..<end])
    }

    /// `str.split()`.
    func split(_ text: Scalars) -> [Scalars] {
        var parts: [Scalars] = []
        var current: Scalars = []
        for point in text {
            if space.contains(point) {
                if !current.isEmpty {
                    parts.append(current)
                    current = []
                }
            } else {
                current.append(point)
            }
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }
}
