import CryptoKit
import Foundation
import Testing
@testable import DawriCore

private struct DriftManifest: Decodable {
    let sources: [String: String]
}

extension Rules {
    /// A clinician's edit to backend/ai/redflags.py must fail here until the exporter is rerun,
    /// because the phone would otherwise keep shipping the old rules without a word.
    @Suite("Rules: engine drift")
    struct EngineDriftTests {
        private static let resources = "ios/DawriCore/Sources/DawriCore/Resources"

        @Test(arguments: ["engine.rules.manifest.json", "engine.clinic.manifest.json"])
        func `every Python source matches its manifest`(manifest: String) throws {
            let data = try Data(contentsOf: Repo.root.appending(path: "\(Self.resources)/\(manifest)"))
            let sources = try JSONDecoder().decode(DriftManifest.self, from: data).sources
            #expect(!sources.isEmpty)
            for (path, expected) in sources.sorted(by: { $0.key < $1.key }) {
                let source = try Data(contentsOf: Repo.root.appending(path: path))
                let found = SHA256.hash(data: source).map { String(format: "%02x", $0) }.joined()
                #expect(found == expected, "\(path) changed: rerun ios/Tools/export-engine-data.py")
            }
        }

        @Test func `the safety sources are all guarded`() throws {
            let data = try Data(
                contentsOf: Repo.root.appending(path: "\(Self.resources)/engine.rules.manifest.json"))
            let sources = try JSONDecoder().decode(DriftManifest.self, from: data).sources
            for name in ["text", "redflags", "refill", "simulated", "receptionist", "filters", "intake"] {
                #expect(sources["backend/ai/\(name).py"] != nil, "\(name).py")
            }
        }
    }
}
