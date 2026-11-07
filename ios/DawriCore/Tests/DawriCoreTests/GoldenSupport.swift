import CryptoKit
import Foundation
import Testing
@testable import DawriCore

/// The three folders under Fixtures/goldens. Their columns are in the docstrings of
/// ios/Tools/export/rules.py, clinic.py and journeys.py.
enum GoldenFolder: String, CaseIterable, Sendable {
    case rules, clinic, journeys
}

enum GoldenError: Error, CustomStringConvertible {
    case notInManifest(String)
    case wrongBytes(String, expected: String, found: String)
    case wrongCount(String, expected: Int, found: Int)

    var description: String {
        switch self {
        case .notInManifest(let file): "\(file) is not in its manifest"
        case .wrongBytes(let file, let expected, let found):
            "\(file) has sha256 \(found), and its manifest says \(expected)"
        case .wrongCount(let file, let expected, let found):
            "\(file) has \(found) cases, and its manifest says \(expected)"
        }
    }
}

/// `String ==` treats canonically equivalent text as equal, so it would pass "é" against "e\u{301}"
/// and hide the very differences the goldens exist to catch. Compare text with this instead.
func sameScalars(_ first: String, _ second: String) -> Bool {
    first.unicodeScalars.elementsEqual(second.unicodeScalars)
}

/// One folder's manifest.json.
struct GoldenManifest: Decodable, Sendable {
    struct File: Decodable, Sendable {
        let family: String
        let count: Int
        let sha256: String
        let bytes: Int
    }

    struct Family: Decodable, Sendable {
        let count: Int
        let minimum: Int
    }

    struct Exclusion: Decodable, Sendable {
        let file: String
        let input: String
        let reason: String
    }

    let schema: Int
    let unidataVersion: String
    let sources: [String: String]
    let families: [String: Family]
    let files: [String: File]
    let excluded: [Exclusion]

    enum CodingKeys: String, CodingKey {
        case schema, sources, families, files, excluded
        case unidataVersion = "unidata_version"
    }
}

/// A loaded golden: its header, its cases, and the count its manifest promises.
///
/// `Case` decodes one row. Rows are arrays, so a case reads them through an unkeyed container,
/// which is far quicker in a debug build than going through `JSONValue`:
///
///     struct RefillCase: Decodable {
///         let text: String
///         init(from decoder: any Decoder) throws {
///             var row = try decoder.unkeyedContainer()
///             _ = try row.decode(Int.self) // family
///             text = try row.decode(String.self)
///         }
///     }
///
///     let golden = try Golden.load(.rules, "refill", as: RefillCase.self)
///     let ran = golden.run { item in #expect(...) }
///     #expect(ran == golden.count)
struct GoldenSet<Case: Decodable>: Decodable {
    let name: String
    let family: String
    /// Everything before `cases` other than the two above, such as `families` or `hits`.
    let header: [String: JSONValue]
    let cases: [Case]
    /// What the manifest says. Loading has already checked that `cases` holds this many.
    private(set) var count = 0

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var header: [String: JSONValue] = [:]
        var cases: [Case] = []
        var name = ""
        var family = ""
        for key in container.allKeys {
            switch key.stringValue {
            case "cases": cases = try container.decode([Case].self, forKey: key)
            case "name": name = try container.decode(String.self, forKey: key)
            case "family": family = try container.decode(String.self, forKey: key)
            default: header[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
        }
        self.name = name
        self.family = family
        self.header = header
        self.cases = cases
    }

    fileprivate func counted(_ count: Int) -> Self {
        var copy = self
        copy.count = count
        return copy
    }

    /// Calls `body` once for each case and returns how many ran, for `#expect(ran == golden.count)`.
    @discardableResult
    func run(_ body: (Case) throws -> Void) rethrows -> Int {
        var ran = 0
        for item in cases {
            try body(item)
            ran += 1
        }
        return ran
    }
}

enum Golden {
    static func folder(_ folder: GoldenFolder) throws -> URL {
        try Fixture.folder.appending(path: "goldens/\(folder.rawValue)")
    }

    static func manifest(_ name: GoldenFolder) throws -> GoldenManifest {
        let data = try Data(contentsOf: try folder(name).appending(path: "manifest.json"))
        return try JSONDecoder().decode(GoldenManifest.self, from: data)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The bytes of a golden, after checking them against the folder's manifest.
    static func data(_ folder: GoldenFolder, _ name: String) throws -> Data {
        let file = "\(name).json"
        guard let entry = try manifest(folder).files[file] else {
            throw GoldenError.notInManifest(file)
        }
        let data = try Data(contentsOf: try self.folder(folder).appending(path: file))
        let found = sha256(data)
        guard found == entry.sha256 else {
            throw GoldenError.wrongBytes(file, expected: entry.sha256, found: found)
        }
        return data
    }

    /// Reads a golden, and throws unless its bytes and its case count match the manifest.
    static func load<Case: Decodable>(
        _ folder: GoldenFolder, _ name: String, as type: Case.Type = Case.self
    ) throws -> GoldenSet<Case> {
        let file = "\(name).json"
        let data = try data(folder, name)
        let loaded = try JSONDecoder().decode(GoldenSet<Case>.self, from: data)
        let expected = try #require(try manifest(folder).files[file]).count
        guard loaded.cases.count == expected else {
            throw GoldenError.wrongCount(file, expected: expected, found: loaded.cases.count)
        }
        return loaded.counted(expected)
    }

    /// Rows in a golden, without decoding it: the writer puts one case on each line.
    static func rowCount(_ data: Data) -> Int {
        data.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } - 2
    }
}

/// The data resources' manifests, which the exporters write beside them.
private struct EngineManifest: Decodable {
    let sources: [String: String]
    let files: [String: String]
}

private let resources = "ios/DawriCore/Sources/DawriCore/Resources"

@Suite("Golden manifests")
struct GoldenManifestTests {
    @Test(arguments: GoldenFolder.allCases)
    func `every manifest entry exists and matches`(folder: GoldenFolder) throws {
        let manifest = try Golden.manifest(folder)
        #expect(!manifest.files.isEmpty)
        for (file, entry) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: try Golden.folder(folder).appending(path: file))
            #expect(data.count == entry.bytes, "\(file)")
            #expect(Golden.sha256(data) == entry.sha256, "\(file)")
            #expect(Golden.rowCount(data) == entry.count, "\(file)")
        }
    }

    @Test(arguments: GoldenFolder.allCases)
    func `a folder holds only what its manifest lists`(folder: GoldenFolder) throws {
        let found = try FileManager.default.contentsOfDirectory(
            at: try Golden.folder(folder), includingPropertiesForKeys: nil)
        let names = Set(found.map(\.lastPathComponent))
        #expect(names == Set(try Golden.manifest(folder).files.keys).union(["manifest.json"]))
    }

    @Test(arguments: GoldenFolder.allCases)
    func `every family meets its minimum`(folder: GoldenFolder) throws {
        let manifest = try Golden.manifest(folder)
        for (family, entry) in manifest.families {
            #expect(entry.count >= entry.minimum, "\(family)")
        }
    }

    @Test(arguments: GoldenFolder.allCases)
    func `every exclusion gives its reason`(folder: GoldenFolder) throws {
        for exclusion in try Golden.manifest(folder).excluded {
            #expect(!exclusion.reason.isEmpty, "\(exclusion.input)")
        }
    }

    @Test(arguments: GoldenFolder.allCases)
    func `the backend has not moved since the goldens were exported`(folder: GoldenFolder) throws {
        for (path, sha) in try Golden.manifest(folder).sources.sorted(by: { $0.key < $1.key }) {
            let data = try Data(contentsOf: Repo.root.appending(path: path))
            #expect(Golden.sha256(data) == sha, "\(path) changed: rerun ios/Tools/export-goldens.py")
        }
    }

    @Test(arguments: ["engine.rules.manifest.json", "engine.clinic.manifest.json"])
    func `the engine data matches the backend it came from`(name: String) throws {
        let data = try Data(contentsOf: Repo.root.appending(path: "\(resources)/\(name)"))
        let manifest = try JSONDecoder().decode(EngineManifest.self, from: data)
        for (path, sha) in manifest.sources.sorted(by: { $0.key < $1.key }) {
            let source = try Data(contentsOf: Repo.root.appending(path: path))
            #expect(Golden.sha256(source) == sha, "\(path) changed: rerun ios/Tools/export-engine-data.py")
        }
        for (file, sha) in manifest.files.sorted(by: { $0.key < $1.key }) {
            let resource = try Data(contentsOf: Repo.root.appending(path: "\(resources)/\(file)"))
            #expect(Golden.sha256(resource) == sha, "\(file) was changed by hand")
        }
    }

    @Test func `text is compared by scalars, not by canonical equivalence`() {
        #expect("\u{E9}" == "e\u{301}")
        #expect(!sameScalars("\u{E9}", "e\u{301}"))
        #expect(sameScalars("\u{E9}", "\u{E9}"))
    }

    @Test func `the loader counts what it runs`() throws {
        let golden = try Golden.load(.clinic, "mock_health", as: JSONValue.self)
        #expect(golden.family == "mock_health")
        let ran = golden.run { _ in }
        #expect(ran == golden.count)
        #expect(ran == golden.cases.count)
    }
}
