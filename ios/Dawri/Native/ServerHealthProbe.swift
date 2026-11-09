import DawriCore
import Foundation

/// The app's one network transport, for Clinic server mode only. Settings' probe and every
/// `RemoteClinicService` share it, so the app never opens a session of its own: DawriCore's
/// `HTTPTransport` is the only place one is made.
enum ClinicNetwork {
    static let transport = HTTPTransport()
}

/// Settings' probe on the phone: `ServerCheck.health`, the two guards of Clinic server mode.
/// The address guard runs again first, so even a URL from somewhere other than the field is
/// refused before any request. Then exactly one `GET /api/health`, no redirect followed, and
/// only `ai_mode: simulated` passes.
///
/// It throws `ServerCheck.Refusal`: `.notSimulated` is Settings' refusedAi, and anything else
/// it says is unreachable.
struct ServerHealthProbe: ServerProbe {
    func probe(url: URL) async throws -> Health {
        try await ServerCheck.health(at: url, transport: ClinicNetwork.transport)
    }
}
