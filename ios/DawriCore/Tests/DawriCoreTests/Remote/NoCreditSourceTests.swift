import Foundation
import Testing
@testable import DawriCore

// The static half of the no-credit promise: a search of everything that builds or tests the app
// for any Hugging Face host, model provider or speech upload. ios/Tools/no-credit-check.sh runs
// the same search, with the same allowlist, from the shell.
//
// No-credit allowlist: this file is a banned list, so it names every banned word on purpose.

/// The folders searched, from the repo root.
private let scanned = [
    "ios/Dawri", "ios/DawriLive", "ios/DawriCore/Sources", "ios/DawriCore/Tests",
    "ios/DawriUITests", "ios/Tools", "ios/Config",
]

/// Matched as plain text, ignoring case.
private let banned = [
    "hf.space", "huggingface", "hf.co", "novita", "featherless", "ovhcloud", "together.ai",
    "openai", "anthropic", "api-inference", "router.huggingface", "whisper", "/api/asr",
]

/// Written in two parts so this file does not itself name the session type.
private let sessionType = "URL" + "Session"

/// A hit that is allowed. `line` nil allows the whole file. `terms` nil allows any banned word.
private struct Allowed {
    let path: String
    let line: String?
    let terms: Set<String>?
    let why: String

    init(_ path: String, line: String? = nil, terms: Set<String>? = nil, why: String) {
        self.path = path
        self.line = line
        self.terms = terms
        self.why = why
    }

    func covers(path hit: String, text: String, terms found: Set<String>) -> Bool {
        let pathMatches = path.hasSuffix("/") ? hit.hasPrefix(path) : hit == path
        guard pathMatches else { return false }
        if let line, !text.contains(line) { return false }
        if let terms, !found.isSubset(of: terms) { return false }
        return true
    }
}

/// Every allowed hit, each with its reason. Keep in step with ios/Tools/no-credit-check.sh.
private let allowed: [Allowed] = [
    // Guard 1 and its tests.
    Allowed("ios/DawriCore/Sources/DawriCore/Patient/ServerAddress.swift",
            why: "the address guard, which refuses these hosts"),
    Allowed("ios/DawriCore/Tests/DawriCoreTests/Patient/ServerAddressTests.swift",
            why: "the address guard's tests"),
    // The Remote guard tests and the banned lists.
    Allowed("ios/DawriCore/Tests/DawriCoreTests/Remote/CreditGuardTests.swift",
            why: "the Remote guard tests: hosts that must be refused, a path that must not appear"),
    Allowed("ios/DawriCore/Tests/DawriCoreTests/Remote/NoCreditSourceTests.swift",
            why: "this banned list"),
    Allowed("ios/Tools/no-credit-check.sh", why: "the shell copy of this banned list"),
    Allowed("ios/DawriCore/Tests/DawriCoreTests/Local/JourneyTests.swift", line: "for banned in [",
            why: "a banned list over the journey's text"),
    Allowed("ios/DawriCore/Tests/DawriCoreTests/DriftTests.swift", line: #"contains("/api/asr\"")"#,
            why: "a guard test: no Swift source names the speech path"),
    // Existing exporter guards.
    Allowed("ios/Tools/export/harvest_plugin.py", line: "NEVER_NAMED = re.compile(",
            why: "the harvest's banned regex"),
    // Settings refusal, in the screenshots and UI tests.
    Allowed("ios/Tools/shots/account.tsv", line: "settings-refused-host",
            why: "the shot of the refused-host message"),
    Allowed("ios/DawriUITests/AccountScreenTests.swift", line: #"app.typeText("https://User@Dawri.HF.Space.:443")"#,
            why: "the refused-host UI test types a forbidden host"),
    Allowed("ios/DawriUITests/AccountScreenTests.swift", line: #""-demoAddress", "https://dawri.hf.space""#,
            why: "the refused-host UI test gives the plain Space address"),
    Allowed("ios/DawriUITests/ServerModeTests.swift",
            why: "the Clinic server UI tests, with their refusal cases"),
    // The golden corpus feeds strings harvested from backend/tests to the rule port as text.
    // Provider names occur there only as rule inputs, never as a host. A Hugging Face host or the
    // speech path would still fail, because only these four words are allowed.
    Allowed("ios/DawriCore/Tests/DawriCoreTests/Fixtures/goldens/",
            terms: ["featherless", "novita", "openai", "whisper"],
            why: "rule-input text harvested from backend tests"),
    Allowed("ios/Tools/export/harvested-inputs.json",
            terms: ["featherless", "novita", "openai", "whisper"],
            why: "the harvested rule-input text the goldens are built from"),
]

/// Where the session type may be named.
private let sessionAllowed: [Allowed] = [
    Allowed("ios/DawriCore/Sources/DawriCore/Remote/", why: "the Clinic server client"),
    Allowed("ios/DawriUITests/ServerModeTests.swift", why: "the live server UI tests"),
]

private struct Hit: CustomStringConvertible {
    let path: String
    let line: Int
    let text: String
    let terms: Set<String>
    var description: String { "\(path):\(line) \(terms.sorted()) \(text.prefix(160))" }
}

/// Every line in the scanned folders holding a banned word, or the session type.
private func search() throws -> (banned: [Hit], session: [Hit]) {
    var bannedHits: [Hit] = []
    var sessionHits: [Hit] = []
    let manager = FileManager.default
    for folder in scanned {
        let root = Repo.root.appending(path: folder)
        guard let walker = manager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [])
        else { continue }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                  let data = try? Data(contentsOf: url)
            else { continue }
            // Every banned word is ASCII, so ASCII case folding of the bytes finds each one. Only a
            // file with a hit is read as text, line by line.
            let folded = Data(data.map { (0x41...0x5A).contains($0) ? $0 | 0x20 : $0 })
            let anyBanned = banned.contains { folded.range(of: Data($0.utf8)) != nil }
            let anySession = data.range(of: Data(sessionType.utf8)) != nil
            guard anyBanned || anySession, let text = String(data: data, encoding: .utf8) else { continue }
            let path = String(url.standardizedFileURL.path.dropFirst(Repo.root.standardizedFileURL.path.count + 1))
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let low = line.lowercased()
                let found = Set(banned.filter { low.contains($0) })
                if !found.isEmpty {
                    bannedHits.append(Hit(path: path, line: index + 1, text: String(line), terms: found))
                }
                if line.contains(sessionType) {
                    sessionHits.append(Hit(path: path, line: index + 1, text: String(line), terms: []))
                }
            }
        }
    }
    return (bannedHits, sessionHits)
}

@Suite("No credits: what the code names")
struct NoCreditSourceTests {
    @Test func `no banned host, provider or speech path outside the allowlist`() throws {
        let hits = try search().banned
        let refused = hits.filter { hit in
            !allowed.contains { $0.covers(path: hit.path, text: hit.text, terms: hit.terms) }
        }
        #expect(refused.isEmpty, "\(refused.map(\.description).joined(separator: "\n"))")
        // The search does find things, so an empty result above is not a broken search.
        #expect(hits.contains { $0.path.hasSuffix("Patient/ServerAddress.swift") })
    }

    @Test func `the session type is only in the Clinic server client`() throws {
        let hits = try search().session
        let refused = hits.filter { hit in
            !sessionAllowed.contains { $0.covers(path: hit.path, text: hit.text, terms: []) }
        }
        #expect(refused.isEmpty, "\(refused.map(\.description).joined(separator: "\n"))")
        #expect(hits.contains { $0.path.hasSuffix("Remote/HTTPTransport.swift") })
    }

    @Test func `the speech path is nowhere in Sources`() throws {
        let hits = try search().banned.filter {
            $0.path.hasPrefix("ios/DawriCore/Sources/") && $0.terms.contains("/api/asr")
        }
        #expect(hits.isEmpty, "\(hits)")
    }

    @Test func `the app allows only local networking`() throws {
        let plist = try plistDictionary("ios/Config/Dawri-Info.plist")
        let ats = try #require(plist["NSAppTransportSecurity"] as? [String: Any])
        #expect(Set(ats.keys) == ["NSAllowsLocalNetworking"])
        #expect(ats["NSAllowsLocalNetworking"] as? Bool == true)
        #expect(!ats.keys.contains { $0.hasPrefix("NSAllowsArbitraryLoads") })
        #expect(ats["NSExceptionDomains"] == nil)
        let usage = try #require(plist["NSLocalNetworkUsageDescription"] as? String)
        #expect(!usage.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Test func `the widget extension has no transport exception`() throws {
        let plist = try plistDictionary("ios/Config/DawriLive-Info.plist")
        #expect(plist["NSAppTransportSecurity"] == nil)
        #expect(plist["NSLocalNetworkUsageDescription"] == nil)
    }

    private func plistDictionary(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Repo.root.appending(path: path))
        let value = try PropertyListSerialization.propertyList(from: data, format: nil)
        return try #require(value as? [String: Any])
    }
}
