import Synchronization

/// Where `RemoteClinicService` keeps the patient's session token, the port of
/// frontend/src/state/token.ts. The service is the only reader: screens never see the token,
/// and nothing logs it.
public protocol TokenStore: Sendable {
    func load() -> String?
    func save(_ token: String)
    func clear()
}

/// A token kept only for the life of this object, as each contract test's service needs.
public final class MemoryTokenStore: TokenStore {
    private let token: Mutex<String?>

    public init(_ token: String? = nil) {
        self.token = Mutex(token)
    }

    public func load() -> String? { token.withLock { $0 } }
    public func save(_ token: String) { self.token.withLock { $0 = token } }
    public func clear() { token.withLock { $0 = nil } }
}
