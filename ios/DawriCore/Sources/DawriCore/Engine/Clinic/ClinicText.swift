import Foundation

/// The Python string behaviour the clinic rules lean on, by scalars, because `String ==` and
/// `String.contains` compare canonically equivalent text as equal and Python does not.
///
/// `lower` is Swift's lowercasing. It differs from `str.lower()` only on a final Greek sigma,
/// and everything it reads here is seed text.
enum ClinicText {
    static func same(_ first: String, _ second: String) -> Bool {
        first.unicodeScalars.elementsEqual(second.unicodeScalars)
    }

    /// `str.strip()`. Python also counts U+001C to U+001F as space, and Unicode does not.
    static func strip(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        func isSpace(_ scalar: Unicode.Scalar) -> Bool {
            scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
        }
        guard let start = scalars.firstIndex(where: { !isSpace($0) }),
              let end = scalars.lastIndex(where: { !isSpace($0) })
        else { return "" }
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars[start...end])
        return String(kept)
    }

    static func lower(_ text: String) -> String {
        text.lowercased()
    }

    /// `needle in haystack`. An empty needle is always found, as in Python.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let hay = Array(haystack.unicodeScalars)
        let wanted = Array(needle.unicodeScalars)
        guard !wanted.isEmpty else { return true }
        guard hay.count >= wanted.count else { return false }
        return (0...(hay.count - wanted.count)).contains { start in
            hay[start..<(start + wanted.count)].elementsEqual(wanted)
        }
    }

    static func hasPrefix(_ text: String, _ prefix: String) -> Bool {
        text.unicodeScalars.starts(with: prefix.unicodeScalars)
    }

    /// `name[0].upper() + name[1:]`, on the first code point and not the first grapheme.
    static func capitalisedFirst(_ name: String) -> String {
        guard let first = name.unicodeScalars.first else { return name }
        var rest = String.UnicodeScalarView()
        rest.append(contentsOf: name.unicodeScalars.dropFirst())
        return String(first).uppercased() + String(rest)
    }

    /// Fills `{key}` once from left to right, as an f-string would, so a value that happens to
    /// hold a placeholder stays as it is. Anything unknown is copied.
    static func fill(_ template: String, _ values: [String: String]) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(template.unicodeScalars)
        var index = 0
        while index < scalars.count {
            if scalars[index] == "{",
               let close = scalars[index...].firstIndex(of: "}") {
                var key = String.UnicodeScalarView()
                key.append(contentsOf: scalars[(index + 1)..<close])
                if let value = values[String(key)] {
                    result.append(contentsOf: value.unicodeScalars)
                    index = close + 1
                    continue
                }
            }
            result.append(scalars[index])
            index += 1
        }
        return String(result)
    }

    /// `round(value, 1)`. Python rounds the exact binary value, so 0.35 goes down because the
    /// stored double is below it. `value * 10` would land on 3.5 and go up. The formatter
    /// gives the correctly rounded decimal, ties to even, in every locale.
    static func roundedToTenth(_ value: Double) -> Double {
        Double(String(format: "%.1f", value)) ?? value
    }
}
