import Foundation
import Synchronization

/// Where `LocalClinicService` keeps its state between launches.
public protocol ClinicStore: Sendable {
    /// Nil when there is nothing usable: no file, a damaged one, or another schema. The service
    /// reseeds, because a demo clinic must always open.
    func load() -> LocalState?
    func save(_ state: LocalState) throws
}

/// One JSON file, replaced whole, so a killed app leaves the old state or the new one and never
/// half of either.
public struct FileClinicStore: ClinicStore {
    public let url: URL

    /// Application Support/Dawri/clinic-state.json
    public static var defaultURL: URL {
        URL.applicationSupportDirectory.appending(path: "Dawri/clinic-state.json")
    }

    public init(url: URL = FileClinicStore.defaultURL) {
        self.url = url
    }

    public func load() -> LocalState? {
        (try? Data(contentsOf: url)).flatMap(LocalState.decoded)
    }

    public func save(_ state: LocalState) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try state.encoded().write(to: url, options: .atomic)
    }
}

/// Holds the same JSON a file would, so tests and DEBUG launches cross the same encoding.
public final class MemoryClinicStore: ClinicStore {
    private let contents: Mutex<Data?>

    public init(data: Data? = nil) {
        contents = Mutex(data)
    }

    public convenience init(state: LocalState) throws {
        self.init(data: try state.encoded())
    }

    public var data: Data? { contents.withLock { $0 } }

    public func load() -> LocalState? {
        data.flatMap(LocalState.decoded)
    }

    public func save(_ state: LocalState) throws {
        let data = try state.encoded()
        contents.withLock { $0 = data }
    }
}
