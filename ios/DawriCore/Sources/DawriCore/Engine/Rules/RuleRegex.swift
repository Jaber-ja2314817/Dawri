import Foundation

/// A match in code points, the way Python reports it. A group that took no part is nil.
struct RegexMatch: Sendable {
    let start: Int
    let end: Int
    let groups: [Range<Int>?]
}

/// One pattern from engine.rules.regex.json, run through NSRegularExpression. The translated
/// pattern holds no ICU `\w`, `\b`, `\d` or `\s`, and offsets come back in code points.
struct RuleRegex: Sendable {
    let name: String
    /// The fixed reading of a `_POINTS_IN_TIME` entry.
    let value: Scalars?
    private let regex: NSRegularExpression
    private let icu: String
    private let caseInsensitive: Bool

    init(name: String, icu: String, caseInsensitive: Bool, value: Scalars?) throws {
        self.name = name
        self.value = value
        self.icu = icu
        self.caseInsensitive = caseInsensitive
        regex = try NSRegularExpression(pattern: icu, options: caseInsensitive ? [.caseInsensitive] : [])
    }

    /// The same pattern held to the whole text: `search` on this is `pattern.fullmatch(text)`.
    func anchored() throws -> RuleRegex {
        try RuleRegex(
            name: "\(name) fullmatch", icu: "\\A(?:\(icu))\\z", caseInsensitive: caseInsensitive,
            value: value)
    }

    /// The subject as UTF-16, and when an astral character makes UTF-16 offsets differ from code
    /// point offsets, the table that converts them.
    private struct Subject {
        let string: NSString
        let offsets: [Int]?

        init(_ text: Scalars) {
            var units: [UInt16] = []
            units.reserveCapacity(text.count)
            var astral = false
            for point in text {
                if point < 0x1_0000 {
                    units.append(UInt16(point))
                } else {
                    astral = true
                    let value = point - 0x1_0000
                    units.append(UInt16(0xD800 + (value >> 10)))
                    units.append(UInt16(0xDC00 + (value & 0x3FF)))
                }
            }
            string = NSString(characters: units, length: units.count)
            guard astral else {
                offsets = nil
                return
            }
            var table: [Int] = []
            table.reserveCapacity(units.count + 1)
            for (index, point) in text.enumerated() {
                table.append(index)
                if point >= 0x1_0000 { table.append(index) }
            }
            table.append(text.count)
            offsets = table
        }

        var everything: NSRange { NSRange(location: 0, length: string.length) }

        func point(_ unit: Int) -> Int { offsets?[unit] ?? unit }

        func match(_ result: NSTextCheckingResult) -> RegexMatch {
            let groups = (1..<max(result.numberOfRanges, 1)).map { index -> Range<Int>? in
                let range = result.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return point(range.location)..<point(range.location + range.length)
            }
            let range = result.range
            return RegexMatch(
                start: point(range.location), end: point(range.location + range.length), groups: groups)
        }
    }

    /// `pattern.finditer(text)`.
    func finditer(_ text: Scalars) -> [RegexMatch] {
        let subject = Subject(text)
        return regex.matches(in: subject.string as String, range: subject.everything).map(subject.match)
    }

    /// `pattern.search(text)`.
    func search(_ text: Scalars) -> RegexMatch? {
        let subject = Subject(text)
        return regex.firstMatch(in: subject.string as String, range: subject.everything).map(subject.match)
    }

    /// `pattern.sub(replacement, text)` with a literal replacement.
    func sub(_ replacement: Scalars, in text: Scalars) -> Scalars {
        var out: Scalars = []
        var position = 0
        for match in finditer(text) {
            out += text[position..<match.start]
            out += replacement
            position = match.end
        }
        out += text[position...]
        return out
    }

    /// `pattern.split(text)`, for a pattern with no groups.
    func split(_ text: Scalars) -> [Scalars] {
        var parts: [Scalars] = []
        var position = 0
        for match in finditer(text) {
            parts.append(Array(text[position..<match.start]))
            position = match.end
        }
        parts.append(Array(text[position...]))
        return parts
    }

    func captured(_ match: RegexMatch, _ group: Int, in text: Scalars) -> Scalars? {
        match.groups[group].map { Array(text[$0]) }
    }
}
