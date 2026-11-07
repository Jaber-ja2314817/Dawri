import Foundation
import Testing
@testable import DawriCore

/// The files index.tsx spreads into a language's dictionary, in its order, without staff.*.
private func patientFiles(_ lang: String) throws -> [String] {
    let source = try Repo.text("frontend/src/i18n/index.tsx")
    let imports = Dictionary(
        uniqueKeysWithValues: source.matches(of: #/import (\w+) from '\./([\w.]+\.json)'/#)
            .map { (String($0.output.1), String($0.output.2)) })
    let start = try #require(source.range(of: "\n  \(lang): {\n"))
    let end = try #require(source.range(of: "\n  },", range: start.upperBound..<source.endIndex))
    return source[start.upperBound..<end.lowerBound].matches(of: #/\.\.\.(\w+)/#)
        .compactMap { imports[String($0.output.1)] }
        .filter { !$0.hasPrefix("staff.") }
}

private func webDictionary(_ lang: String) throws -> [String: String] {
    var merged: [String: String] = [:]
    for file in try patientFiles(lang) {
        merged.merge(try Repo.dictionary("frontend/src/i18n/\(file)")) { _, later in later }
    }
    return merged
}

private func placeholders(_ text: String) -> Set<String> {
    Set(text.matches(of: #/\{([A-Za-z0-9_]+)\}/#).map { String($0.output.1) })
}

@Suite("Drift between the web, the sync script and the bundle")
struct DriftTests {
    private var bundled: [Lang: [String: String]] { Strings.bundled.dictionaries }

    @Test(arguments: [(Lang.en, "en"), (Lang.ar, "ar")])
    func `the bundle is the web's strings plus the phone's`(lang: Lang, name: String) throws {
        let web = try webDictionary(name)
        let phone = try Repo.dictionary("ios/Tools/strings/ios.\(name).json")
        #expect(Set(web.keys).isDisjoint(with: phone.keys))
        let derived = web.merging(phone) { first, _ in first }
        let actual = try #require(bundled[lang])
        for key in Set(derived.keys).union(actual.keys).sorted() where derived[key] != actual[key] {
            Issue.record("\(name) \(key) differs: \(derived[key] ?? "(none)") against \(actual[key] ?? "(none)")")
        }
    }

    @Test func `the patient files are the three the app expects`() throws {
        #expect(try patientFiles("en") == ["en.json", "chat.en.json", "visit.en.json"])
        #expect(try patientFiles("ar") == ["ar.json", "chat.ar.json", "visit.ar.json"])
    }

    @Test func `Arabic and English have the same keys`() throws {
        #expect(Set(try #require(bundled[.ar]).keys) == Set(try #require(bundled[.en]).keys))
    }

    @Test func `each key has the same placeholders in both languages`() throws {
        let arabic = try #require(bundled[.ar])
        for (key, english) in try #require(bundled[.en]) {
            #expect(placeholders(english) == placeholders(arabic[key] ?? ""), "\(key)")
        }
    }

    @Test func `no staff key is bundled`() throws {
        for dictionary in bundled.values {
            #expect(!dictionary.keys.contains { $0.hasPrefix("staff.") })
        }
    }

    @Test func `the footer stands in both languages`() throws {
        #expect(Strings.bundled.translate(.en, "footer.demo")
            == "Demo — synthetic data, not connected to PHCC/HMC systems.")
        #expect(Strings.bundled.translate(.ar, "footer.demo")
            == "تجريبي — بيانات اصطناعية، غير متصل بأنظمة PHCC/HMC.")
        #expect(Strings.bundled.translate(.en, "footer.ai") == "AI: simulated")
        #expect(Strings.bundled.translate(.ar, "footer.ai") != "footer.ai")
    }

    @Test func `the record table matches record.ts`() throws {
        let source = try Repo.text("frontend/src/i18n/record.ts")
        let start = try #require(source.range(of: "const ARABIC"))
        let end = try #require(source.range(of: "\n}", range: start.upperBound..<source.endIndex))
        let lines = source[start.upperBound..<end.lowerBound].split(separator: "\n").dropFirst()
        #expect(lines.count == Strings.bundled.recordTerms.count)
        for (key, value) in Strings.bundled.recordTerms {
            #expect(lines.contains { $0.contains(key) && $0.contains(value) }, "\(key)")
        }
    }

    @Test func `every error code the web can show has its sentence`() throws {
        let source = try Repo.text("frontend/src/i18n/i18n.test.ts")
        let start = try #require(source.range(of: "const ERROR_CODES = `"))
        let end = try #require(source.range(of: "`.split", range: start.upperBound..<source.endIndex))
        let codes = source[start.upperBound..<end.lowerBound].split(whereSeparator: \.isWhitespace)
        #expect(codes.count > 40)
        for code in codes {
            let key = "error.\(code)"
            #expect(Strings.bundled.translate(.ar, key) != key)
        }
    }
}

@Suite("Coverage of the web's API")
struct CoverageTests {
    private static func swiftSources() throws -> String {
        let folder = Repo.root.appending(path: "ios/DawriCore/Sources/DawriCore")
        let walker = try #require(FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil))
        var joined = ""
        for case let url as URL in walker where url.pathExtension == "swift" {
            joined += try String(contentsOf: url, encoding: .utf8)
        }
        return joined
    }

    @Test func `every name in types.ts has a Swift type`() throws {
        let source = try Repo.text("frontend/src/api/types.ts")
        let names = source.matches(of: #/export (?:interface|type) ([A-Za-z]+)/#)
            .map { String($0.output.1) }
        #expect(names.count == 31)

        let swift = try Self.swiftSources()
        let declared = Set(swift.matches(of: #/public (?:struct|enum) ([A-Za-z]+)/#)
            .map { String($0.output.1) })
        for name in names {
            #expect(declared.contains(name), "No Swift type named \(name)")
        }
    }

    @Test func `every export of endpoints.ts is on the protocol, except transcribe`() throws {
        let source = try Repo.text("frontend/src/api/endpoints.ts")
        let exports = source.matches(of: #/export const ([A-Za-z]+) =/#).map { String($0.output.1) }
        #expect(exports.contains("transcribe"))

        let service = try Repo.text("ios/DawriCore/Sources/DawriCore/Service/ClinicService.swift")
        for name in exports where name != "transcribe" {
            #expect(service.contains("func \(name)("), "No protocol method for \(name)")
        }
        #expect(!service.contains("func transcribe"))
        for name in ["sendChat", "signOut", "visitUpdates"] {
            #expect(service.contains("func \(name)("))
        }
    }

    @Test func `the app never calls asr`() throws {
        #expect(!(try Self.swiftSources()).contains("/api/asr\""))
    }
}
