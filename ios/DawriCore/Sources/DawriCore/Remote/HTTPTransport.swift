import Foundation

/// The only way DawriCore reaches the network, and only for Clinic server mode. Nothing outside
/// `Remote/` holds a session.
///
/// It sends whatever request it is handed, so it never decides where to go. `ServerCheck` and
/// `RemoteClinicService` build every request from a base that passed `ServerAddress`, pin its
/// scheme, host and port, and check them again before calling this.
///
/// What the sessions keep is nothing:
/// - ephemeral, with no cookies, no URL cache and no credential storage
/// - no waiting for connectivity, so a server that is not there fails at once
/// - redirects are never followed: a 30x comes back as the answer, so a health check cannot be
///   bounced to another host
/// - nothing is logged, so a bearer token never reaches a log
public final class HTTPTransport: Sendable {
    /// For ordinary requests. The chat has its own 45 s limit on top of this.
    public static let requestTimeout: TimeInterval = 20
    /// For the event stream. Above the server's 15 s heartbeat, so a quiet stream stays open and a
    /// dead one ends.
    public static let streamTimeout: TimeInterval = 60

    private let session: URLSession
    private let streamSession: URLSession

    /// The app's transport, on the system's own loaders.
    public convenience init() {
        self.init(protocolClasses: nil)
    }

    /// - Parameter protocolClasses: replaces every loader the sessions would use. Tests pass only a
    ///   recording stub, so no request they make can reach the network. Nil keeps the system's.
    public init(protocolClasses: [AnyClass]?) {
        let refusal = RedirectRefusal()
        session = URLSession(
            configuration: Self.configuration(
                requestTimeout: Self.requestTimeout, resourceTimeout: 60,
                protocolClasses: protocolClasses),
            delegate: refusal, delegateQueue: nil)
        streamSession = URLSession(
            configuration: Self.configuration(
                requestTimeout: Self.streamTimeout, resourceTimeout: 7 * 24 * 3600,
                protocolClasses: protocolClasses),
            delegate: refusal, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
        streamSession.invalidateAndCancel()
    }

    private static func configuration(
        requestTimeout: TimeInterval, resourceTimeout: TimeInterval, protocolClasses: [AnyClass]?
    ) -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        return configuration
    }

    /// One request, read whole. A redirect is returned, not followed.
    ///
    /// - Throws: `CancellationError` when the calling task was cancelled, so a time limit can end
    ///   a request. Any other failure is the loader's own error, usually a `URLError`.
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await cancellable {
            let (data, response) = try await session.data(for: request)
            return (data, try Self.http(response))
        }
    }

    /// A long-lived response, read as it arrives. The caller owns the reading task: cancelling it
    /// ends the request.
    func stream(for request: URLRequest) async throws -> (URLSession.AsyncBytes, HTTPURLResponse) {
        try await cancellable {
            let (bytes, response) = try await streamSession.bytes(for: request)
            return (bytes, try Self.http(response))
        }
    }

    private static func http(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        return http
    }

    /// The loader reports a cancelled task as `URLError.cancelled`. Callers above rely on
    /// `CancellationError`, as the chat's 45 s limit does.
    private func cancellable<T>(_ work: () async throws -> T) async throws -> T {
        do {
            let value = try await work()
            try Task.checkCancellation()
            return value
        } catch let error as URLError where error.code == .cancelled || Task.isCancelled {
            throw CancellationError()
        } catch where Task.isCancelled {
            throw CancellationError()
        }
    }
}

/// Every redirect is refused. With nil, the session hands back the 30x itself as the answer.
private final class RedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
