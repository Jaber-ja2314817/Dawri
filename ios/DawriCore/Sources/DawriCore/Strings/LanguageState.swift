import Foundation
import Observation

/// Where the language choice is kept. Injected, so tests and previews keep their own.
public protocol KeyValueStore {
    func read(_ key: String) -> String?
    func write(_ value: String, for key: String)
    func remove(_ key: String)
}

extension UserDefaults: KeyValueStore {
    public func read(_ key: String) -> String? { string(forKey: key) }
    public func write(_ value: String, for key: String) { set(value, forKey: key) }
    public func remove(_ key: String) { removeObject(forKey: key) }
}

/// The language rules of frontend/src/i18n/index.tsx. Arabic by default. A tapped choice
/// outranks the record until logout, and the screens follow `lang` with no restart.
@MainActor
@Observable
public final class LanguageState {
    private static let langKey = "dawri.lang"
    private static let chosenKey = "dawri.lang.chosen"

    public private(set) var lang: Lang
    private var chosen: Bool
    @ObservationIgnored private let store: any KeyValueStore

    public init(store: any KeyValueStore) {
        self.store = store
        self.lang = store.read(Self.langKey).flatMap(Lang.init(rawValue:)) ?? .ar
        self.chosen = store.read(Self.chosenKey) == "1"
    }

    public var dir: Dir { dirOf(lang) }

    /// The viewer's own choice. It outranks the record until logout.
    public func setLang(_ next: Lang) {
        lang = next
        chosen = true
        store.write(next.rawValue, for: Self.langKey)
        store.write("1", for: Self.chosenKey)
    }

    /// On login: the record's language, unless the viewer already chose one.
    public func applyPreferred(_ preferred: String) {
        guard !chosen else { return }
        let next: Lang = preferred == "en" ? .en : .ar
        lang = next
        store.write(next.rawValue, for: Self.langKey)
    }

    /// On logout: back to the default, with the viewer's choice forgotten.
    public func reset() {
        lang = .ar
        chosen = false
        store.remove(Self.langKey)
        store.remove(Self.chosenKey)
    }
}
