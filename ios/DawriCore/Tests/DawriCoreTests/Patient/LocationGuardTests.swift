import Foundation
import Testing

/// The location promise, read from the app's sources: Core Location is read once, on the patient's
/// tap, through `CoreLocationSource`, and nothing else in the app or the Live extension follows,
/// monitors or shows the phone's position. That is what NSLocationWhenInUseUsageDescription says
/// in both languages, so a map dot, a geofence or an Always request would break it.
@Suite("Patient: location source guards")
struct LocationGuardTests {
    /// The only file that may hold a `CLLocationManager`.
    private static let reader = "ios/Dawri/Native/CoreLocationSource.swift"

    /// APIs that track, monitor or show the patient's position, or ask for more than when in use.
    private static let forbidden = [
        "UserAnnotation",
        "showsUserLocation",
        "startUpdatingLocation",
        "MapUserLocationButton",
        "startMonitoring",
        "CLMonitor",
        "requestAlwaysAuthorization",
    ]

    /// Every `.swift` file under the app and the Live extension, as repo-relative paths.
    private static func appSources() throws -> [String] {
        var paths: [String] = []
        for folder in ["ios/Dawri", "ios/DawriLive"] {
            let base = Repo.root.appending(path: folder)
            let enumerator = try #require(
                FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = url.standardizedFileURL.path
                    .replacingOccurrences(of: Repo.root.standardizedFileURL.path + "/", with: "")
                paths.append(relative)
            }
        }
        return paths.sorted()
    }

    @Test func `the guard reads the real app sources`() throws {
        let sources = try Self.appSources()
        #expect(sources.contains("ios/Dawri/Screens/Visit/CentreMap.swift"))
        #expect(sources.contains(Self.reader))
        #expect(sources.contains { $0.hasPrefix("ios/DawriLive/") })
        #expect(try Repo.text(Self.reader).contains("CLLocationManager()"))
    }

    @Test func `nothing follows, monitors or shows the patient's position`() throws {
        for file in try Self.appSources() {
            let text = try Repo.text(file)
            for name in Self.forbidden {
                #expect(!text.contains(name), "\(file) uses \(name)")
            }
        }
    }

    @Test func `CLLocationManager lives only in CoreLocationSource`() throws {
        for file in try Self.appSources() where file != Self.reader {
            #expect(!(try Repo.text(file)).contains("CLLocationManager"), "\(file)")
        }
    }
}
