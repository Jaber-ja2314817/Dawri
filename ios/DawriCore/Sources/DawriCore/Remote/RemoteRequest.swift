import Foundation

/// How every Clinic server request is built: the base's scheme, host and port, pinned, plus a
/// fixed path. Nothing a server sends back can choose where the next request goes, because a
/// visit id is only ever one encoded path segment.
enum RemoteRequest {
    /// `encodeURIComponent`, as `visitPath` in frontend/src/api/endpoints.ts uses it.
    static func pathSegment(_ text: String) -> String {
        percentEncoded(text, keeping: componentSafe, spaceAsPlus: false)
    }

    /// `new URLSearchParams(...).toString()`, in the order given.
    static func formQuery(_ items: [(String, String)]) -> String {
        items.map { name, value in
            percentEncoded(name, keeping: formSafe, spaceAsPlus: true) + "="
                + percentEncoded(value, keeping: formSafe, spaceAsPlus: true)
        }.joined(separator: "&")
    }

    /// `String(number)` in JavaScript, for the plain coordinates the web sends: a whole number has
    /// no `.0`.
    static func jsNumber(_ value: Double) -> String {
        guard value.isFinite else { return value.isNaN ? "NaN" : (value < 0 ? "-Infinity" : "Infinity") }
        if value == value.rounded(), abs(value) < 1e15 { return String(Int64(value)) }
        return String(value)
    }

    /// The base with only `path` and `query` set. Throws unless the result has the base's own
    /// scheme, host and port, and no user, so a request cannot leave the server that was checked.
    static func url(base: URL, path: String, query: [(String, String)] = []) throws -> URL {
        precondition(path.hasPrefix("/api/"), "Every Clinic server path is under /api/")
        guard var parts = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw offHost
        }
        parts.user = nil
        parts.password = nil
        parts.fragment = nil
        parts.percentEncodedPath = path
        parts.percentEncodedQuery = query.isEmpty ? nil : formQuery(query)
        guard let url = parts.url, sameOrigin(url, base) else { throw offHost }
        return url
    }

    static func sameOrigin(_ url: URL, _ base: URL) -> Bool {
        url.scheme == base.scheme && url.host(percentEncoded: true) == base.host(percentEncoded: true)
            && url.port == base.port && url.user == nil && url.password == nil
            && base.host(percentEncoded: true)?.isEmpty == false
    }

    /// Only reachable through a bug in this file. Status 403 because nothing was sent.
    static let offHost = ClinicError(
        status: 403, code: "internal_error",
        message: "The app refused to send a request away from the clinic server.")

    // Encoding

    private static let alphanumerics = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789".utf8)
    private static let componentSafe = alphanumerics.union("-_.!~*'()".utf8)
    private static let formSafe = alphanumerics.union("*-._".utf8)

    private static func percentEncoded(
        _ text: String, keeping safe: Set<UInt8>, spaceAsPlus: Bool
    ) -> String {
        var out = ""
        for byte in text.utf8 {
            if safe.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else if spaceAsPlus, byte == 0x20 {
                out += "+"
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return out
    }
}

extension String {
    fileprivate func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(width - count, 0)) + self
    }
}
