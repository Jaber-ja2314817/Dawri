import DawriCore
import Foundation
import Security
import Synchronization

/// Where Clinic server mode keeps the patient's session token on the phone: one generic
/// password in the app's own Keychain, so a relaunch in server mode stays signed in. It needs no
/// entitlement and no App Group, so a free Personal Team signs it.
///
/// - `kSecClassGenericPassword`, one item, service `<bundle id>.clinic-server`, account `session`.
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: never in a backup, never on another phone,
///   and unreadable while the phone is locked. The app reads it only while it runs in front.
/// - Only `RemoteClinicService` reads it, through `TokenStore`. Nothing logs it.
///
/// On this phone mode never touches it, so the two modes never share a session.
final class KeychainTokenStore: TokenStore {
    private static let account = "session"

    private let service: String
    /// What the Keychain holds, read once. `.some(nil)` means "read, and empty".
    private let cache = Mutex<String??>(nil)

    init(service: String = (Bundle.main.bundleIdentifier ?? "com.jaber.dawri") + ".clinic-server") {
        self.service = service
    }

    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: Self.account,
        ]
    }

    func load() -> String? {
        cache.withLock { cached in
            if let cached { return cached }
            var lookup = query
            lookup[kSecReturnData as String] = true
            lookup[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(lookup as CFDictionary, &item)
            let token = status == errSecSuccess
                ? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                : nil
            cached = .some(token)
            return token
        }
    }

    func save(_ token: String) {
        cache.withLock { cached in
            let data = Data(token.utf8)
            let update = [kSecValueData as String: data] as CFDictionary
            if SecItemUpdate(query as CFDictionary, update) == errSecItemNotFound {
                var add = query
                add[kSecValueData as String] = data
                add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
                _ = SecItemAdd(add as CFDictionary, nil)
            }
            // A failed write keeps the token for this run only: the patient signs in again after
            // a relaunch, which is safe.
            cached = .some(token)
        }
    }

    func clear() {
        cache.withLock { cached in
            SecItemDelete(query as CFDictionary)
            cached = .some(nil)
        }
    }
}
