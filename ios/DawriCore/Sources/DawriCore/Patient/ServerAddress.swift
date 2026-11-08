import Foundation

/// The first guard of Clinic server mode, and part of the product's promise that this app cannot
/// spend credits. It reads what was typed and either gives back a plain base URL or refuses it.
/// It is pure: it resolves nothing and sends nothing, so a refused address never reaches the
/// health probe.
///
/// What it accepts is narrow on purpose:
/// - `scheme://host[:port]` with an optional trailing `/`. No user info, path, query or fragment.
/// - Printable ASCII only, with no `%` escapes, so no look-alike letters, invisible characters or
///   encoded dots can hide a host.
/// - A host that is a plain DNS name, a strict dotted IPv4 address, or a bracketed IPv6 address.
/// - Never a Hugging Face host: anything ending in `hf.space` or `hf.co`, or naming
///   `huggingface`, whatever the case, trailing dot, user info or port.
/// - `http` only on a local address: `localhost`, `*.local`, 127/8, 10/8, 172.16/12, 192.168/16,
///   169.254/16, `::1` and fe80::/10. `https` anywhere else.
///
/// With no scheme typed, a local host is taken as `http` and any other as `https`.
public enum ServerAddress {
    public enum Refusal: Sendable, Equatable {
        /// Nothing was typed.
        case empty
        /// A Hugging Face host. The one this guard exists for.
        case forbiddenHost
        /// Not `http` or `https`.
        case unsupportedScheme
        /// `http` to a host that is not on the local network.
        case insecure
        /// A name before `@`.
        case userInfo
        /// Anything after the host and port but a single `/`.
        case path
        /// Characters or a shape this guard will not read.
        case malformed
    }

    public enum Verdict: Sendable, Equatable {
        case ok(URL)
        case refused(Refusal)

        public var url: URL? {
            if case .ok(let url) = self { url } else { nil }
        }
    }

    public static func parse(_ typed: String) -> Verdict {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .refused(.empty) }
        guard text.unicodeScalars.allSatisfy({ (0x21...0x7E).contains($0.value) }), !text.contains("%")
        else { return .refused(.malformed) }
        let lowered = text.lowercased()
        // Before any other reading, so no other refusal can stand in front of this one.
        if namesHuggingFace(lowered) { return .refused(.forbiddenHost) }

        var scheme: String?
        var rest = Substring(lowered)
        if let mark = lowered.range(of: "://") {
            scheme = String(lowered[..<mark.lowerBound])
            rest = lowered[mark.upperBound...]
        }
        if let scheme, scheme != "http", scheme != "https" { return .refused(.unsupportedScheme) }

        let end = rest.firstIndex { "/?#\\".contains($0) } ?? rest.endIndex
        let authority = rest[..<end]
        let tail = rest[end...]
        guard tail.isEmpty || tail == "/" else { return .refused(.path) }
        if let at = authority.lastIndex(of: "@") {
            // The host a client would use is after the last `@`, so name it first if it is one.
            if let (host, _) = splitAuthority(authority[authority.index(after: at)...]),
               isForbidden(host: host.name) {
                return .refused(.forbiddenHost)
            }
            return .refused(.userInfo)
        }

        guard let (host, port) = splitAuthority(authority) else { return .refused(.malformed) }
        if isForbidden(host: host.name) { return .refused(.forbiddenHost) }

        let local = isLocal(host)
        let chosen = scheme ?? (local ? "http" : "https")
        if chosen == "http", !local { return .refused(.insecure) }

        let hostText = host.isIPv6 ? "[\(host.name)]" : host.name
        let portText = port.map { ":\($0)" } ?? ""
        guard let url = URL(string: "\(chosen)://\(hostText)\(portText)") else {
            return .refused(.malformed)
        }
        return .ok(url)
    }

    // Hugging Face

    /// Anywhere in the text, so an address that so much as names one is refused.
    private static func namesHuggingFace(_ text: String) -> Bool {
        text.contains("huggingface") || text.contains("hf.space")
    }

    private static func isForbidden(host: String) -> Bool {
        host.hasSuffix("hf.space") || host.contains("huggingface") || host == "hf.co"
            || host.hasSuffix(".hf.co")
    }

    // Host and port

    private struct Host {
        /// Lower case, with no trailing dot, and no brackets on IPv6.
        let name: String
        let isIPv6: Bool
        /// The four octets of a dotted IPv4 address.
        let ipv4: [Int]?
        /// The eight groups of an IPv6 address.
        let ipv6: [Int]?
    }

    private static func splitAuthority(_ authority: Substring) -> (Host, Int?)? {
        guard !authority.isEmpty else { return nil }
        if authority.hasPrefix("[") {
            guard let close = authority.firstIndex(of: "]") else { return nil }
            let inside = authority[authority.index(after: authority.startIndex)..<close]
            let after = authority[authority.index(after: close)...]
            guard let groups = ipv6Groups(inside) else { return nil }
            let port: Int?
            if after.isEmpty {
                port = nil
            } else {
                guard after.hasPrefix(":"), let parsed = parsePort(after.dropFirst()) else { return nil }
                port = parsed
            }
            return (Host(name: String(inside), isIPv6: true, ipv4: nil, ipv6: groups), port)
        }

        var name = authority
        var port: Int?
        if let colon = authority.lastIndex(of: ":") {
            name = authority[..<colon]
            guard let parsed = parsePort(authority[authority.index(after: colon)...]) else { return nil }
            port = parsed
        }
        if name.hasSuffix(".") { name = name.dropLast() }
        guard let host = dnsHost(name) else { return nil }
        return (host, port)
    }

    /// 1 to 65535, in plain digits.
    private static func parsePort(_ text: Substring) -> Int? {
        guard (1...5).contains(text.count), text.allSatisfy(\.isASCIIDigit), let value = Int(text),
              (1...65_535).contains(value)
        else { return nil }
        return value
    }

    /// A DNS name or a strict dotted IPv4 address. A name whose last label is all digits, or that
    /// starts like a hex number, could be read as an address by a resolver, so it must be a
    /// strict dotted quad or nothing.
    private static func dnsHost(_ name: Substring) -> Host? {
        guard !name.isEmpty, name.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isASCIILetter || $0.isASCIIDigit || $0 == "-" })
            else { return nil }
        }
        let numeric = labels.last.map { $0.allSatisfy(\.isASCIIDigit) } ?? false
        let hexLike = labels.contains { $0.hasPrefix("0x") }
        if numeric || hexLike {
            guard let octets = ipv4Octets(labels) else { return nil }
            return Host(name: String(name), isIPv6: false, ipv4: octets, ipv6: nil)
        }
        return Host(name: String(name), isIPv6: false, ipv4: nil, ipv6: nil)
    }

    /// Exactly four decimal octets, with no leading zero that a resolver could read as octal.
    private static func ipv4Octets(_ labels: [Substring]) -> [Int]? {
        guard labels.count == 4 else { return nil }
        var octets: [Int] = []
        for label in labels {
            guard label.allSatisfy(\.isASCIIDigit), label.count <= 3,
                  label == "0" || !label.hasPrefix("0"), let value = Int(label), value <= 255
            else { return nil }
            octets.append(value)
        }
        return octets
    }

    /// Hex groups with at most one `::`. Embedded IPv4 and zone indices are not accepted.
    private static func ipv6Groups(_ text: Substring) -> [Int]? {
        guard !text.isEmpty, text.allSatisfy({ $0.isHexDigit || $0 == ":" }) else { return nil }
        let halves = text.components(separatedBy: "::")
        guard halves.count <= 2 else { return nil }
        func groups(_ part: String) -> [Int]? {
            if part.isEmpty { return [] }
            var values: [Int] = []
            for group in part.split(separator: ":", omittingEmptySubsequences: false) {
                guard (1...4).contains(group.count), let value = Int(group, radix: 16) else { return nil }
                values.append(value)
            }
            return values
        }
        guard let head = groups(halves[0]) else { return nil }
        if halves.count == 1 { return head.count == 8 ? head : nil }
        guard let tail = groups(halves[1]), head.count + tail.count < 8 else { return nil }
        return head + Array(repeating: 0, count: 8 - head.count - tail.count) + tail
    }

    // Local addresses

    private static func isLocal(_ host: Host) -> Bool {
        if let groups = host.ipv6 {
            let loopback = groups == [0, 0, 0, 0, 0, 0, 0, 1]
            let linkLocal = groups[0] & 0xFFC0 == 0xFE80
            return loopback || linkLocal
        }
        if let octets = host.ipv4 {
            switch (octets[0], octets[1]) {
            case (127, _), (10, _), (192, 168), (169, 254): return true
            case (172, let second): return (16...31).contains(second)
            default: return false
            }
        }
        return host.name == "localhost" || host.name.hasSuffix(".local")
    }
}

extension Character {
    fileprivate var isASCIIDigit: Bool { isASCII && isNumber }
    fileprivate var isASCIILetter: Bool { isASCII && isLetter }
}
