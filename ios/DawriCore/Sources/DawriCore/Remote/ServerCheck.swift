import Foundation

/// The check before Clinic server mode connects, and the two guards that make it safe: the
/// address guard, then the simulated-mode guard. Settings' probe is built on it.
///
/// 1. `ServerAddress.parse` reads what was typed. A refusal throws `.address` before any request
///    exists, so a Hugging Face host, or `http` to a public host, is never contacted at all.
/// 2. Then `GET <base>/api/health`, and nothing else. A redirect is not followed.
/// 3. Only `ai_mode: simulated` passes. `real`, any other mode, or an answer that is not a health
///    reply throws `.notSimulated`, so the app never uses a server that could spend credits.
///
/// ```swift
/// do {
///     let server = try await ServerCheck.connect(to: typed, transport: transport)
///     // server.baseURL, server.health
/// } catch let refusal as ServerCheck.Refusal {
///     // .address(_) → refusedHost, .notSimulated(_) → refusedAi, .unreachable → unreachable
/// }
/// ```
public enum ServerCheck {
    public enum Refusal: Error, Sendable, Equatable {
        /// `ServerAddress` refused what was typed. Nothing was sent.
        case address(ServerAddress.Refusal)
        /// The server answered, but not with `ai_mode: simulated`. Holds the mode it gave, or nil
        /// when the answer was not a health reply at all.
        case notSimulated(AiMode?)
        /// No answer: the connection failed, timed out, or gave a status other than 200, a
        /// redirect included.
        case unreachable
    }

    /// A server that passed both guards.
    public struct Connection: Sendable, Equatable {
        /// `scheme://host[:port]`, exactly as `ServerAddress` gave it.
        public let baseURL: URL
        public let health: Health
    }

    /// Both guards, in order, for a typed address.
    ///
    /// - Throws: `Refusal`, or `CancellationError` when the calling task is cancelled.
    public static func connect(to typed: String, transport: HTTPTransport) async throws -> Connection {
        switch ServerAddress.parse(typed) {
        case .refused(let refusal):
            throw Refusal.address(refusal)
        case .ok(let base):
            return Connection(baseURL: base, health: try await health(at: base, transport: transport))
        }
    }

    /// The health guard alone, for a base URL that has already passed `ServerAddress`, as on a
    /// relaunch in server mode. The base is checked again first, so a URL from anywhere else is
    /// refused with `.address` before any request.
    ///
    /// - Throws: `Refusal`, or `CancellationError` when the calling task is cancelled.
    public static func health(at base: URL, transport: HTTPTransport) async throws -> Health {
        if let refusal = refusal(of: base) { throw Refusal.address(refusal) }
        let reply = try await read(base: base, token: nil, transport: transport)
        switch reply {
        case .failed, .status: throw Refusal.unreachable
        case .health(let health): return health
        case .notSimulated(let mode): throw Refusal.notSimulated(mode)
        }
    }

    /// Nil when `base` is exactly what `ServerAddress` gives for it.
    static func refusal(of base: URL) -> ServerAddress.Refusal? {
        switch ServerAddress.parse(base.absoluteString) {
        case .refused(let refusal): refusal
        case .ok(let parsed): parsed == base ? nil : .malformed
        }
    }

    // The one request

    enum Reply: Sendable {
        case health(Health)
        case notSimulated(AiMode?)
        /// A status other than 200, with its body.
        case status(Int, Data)
        case failed
    }

    /// `GET /api/health`, shared with `RemoteClinicService`'s gate so both read it the same way.
    static func read(base: URL, token: String?, transport: HTTPTransport) async throws -> Reply {
        var request = URLRequest(url: try RemoteRequest.url(base: base, path: "/api/health"))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failed
        }
        guard response.statusCode == 200 else { return .status(response.statusCode, data) }
        guard let health = try? JSONDecoder().decode(Health.self, from: data) else {
            return .notSimulated(nil)
        }
        return health.aiMode == .simulated ? .health(health) : .notSimulated(health.aiMode)
    }
}
