import Foundation
import Synchronization
import Testing
@testable import DawriCore

/// One request as the stub received it.
struct Recorded: Sendable, Equatable, CustomStringConvertible {
    let method: String
    let url: URL
    let headers: [String: String]
    let body: Data?

    var path: String { url.path(percentEncoded: true) }
    var query: String? { url.query(percentEncoded: true) }
    /// `GET /api/health`
    var line: String { "\(method) \(path)" }
    var description: String { "\(method) \(url.absoluteString)" }

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: JSONValue? {
        body.flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
    }
}

/// What the stub answers.
enum StubReply: Sendable {
    /// A status and a body, sent as JSON.
    case json(Int, String)
    /// A status, a raw body and its content type.
    case body(Int, Data, contentType: String)
    /// A 30x to `URL`, the way the system's HTTP loader reports one.
    case redirect(Int, URL)
    /// The connection fails with this code.
    case fail(URLError.Code)
    /// A 200 `text/event-stream`, sent as these chunks. With `end`, the response then finishes.
    /// Without it the stream stays open until `push` or the client cancels.
    case events([String], end: Bool)
    /// Another status on the stream route.
    case streamStatus(Int)

    static func health(_ mode: String) -> StubReply {
        .json(200, #"{"status":"ok","ai_mode":"\#(mode)","simulate_load":true}"#)
    }
}

/// A fake Clinic server at a host of its own, so tests running in parallel never share one.
/// It records every request it receives, in order. A request with no route is answered with a
/// connection failure and kept in `unexpected`, which `expectNoSurprises` checks.
final class StubServer: Sendable {
    private static let counter = Atomic<Int>(0)

    let base: URL
    let transport: HTTPTransport

    private let routes = Mutex<[String: [StubReply]]>([:])
    private let log = Mutex<[Recorded]>([])
    private let strays = Mutex<[Recorded]>([])
    private let open = Mutex<[HeldStream]>([])

    /// - Parameter health: what `/api/health` says, until a test sets it again.
    init(health: String = "simulated") {
        let number = Self.counter.add(1, ordering: .relaxed).newValue
        base = URL(string: "http://stub\(number).local:8100")!
        transport = HTTPTransport(protocolClasses: [StubProtocol.self])
        StubProtocol.register(self)
        on("GET", "/api/health", .health(health))
    }

    /// Replies for `METHOD path`, given in turn. The last one repeats.
    func on(_ method: String, _ path: String, _ replies: StubReply...) {
        routes.withLock { $0["\(method) \(path)"] = replies }
    }

    var requests: [Recorded] { log.withLock { $0 } }
    var lines: [String] { requests.map(\.line) }
    var unexpected: [Recorded] { strays.withLock { $0 } }
    var last: Recorded? { requests.last }

    func expectNoSurprises(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(unexpected.isEmpty, "Requests with no route: \(unexpected)", sourceLocation: sourceLocation)
    }

    /// A service on this server, with its own token store.
    func service(token: String? = nil) throws -> RemoteClinicService {
        try RemoteClinicService(baseURL: base, transport: transport, tokens: MemoryTokenStore(token))
    }

    /// Sends a chunk on every stream this server is holding open.
    func push(_ chunk: String) {
        for held in open.withLock({ $0 }) { held.send(Data(chunk.utf8)) }
    }

    /// Ends every stream this server is holding open, as the server going away would.
    func endStreams() {
        for held in open.withLock({ $0 }) { held.finish() }
        open.withLock { $0.removeAll() }
    }

    var openStreams: Int { open.withLock { $0.count } }

    // Called by StubProtocol

    fileprivate func reply(to request: Recorded) -> StubReply? {
        let key = request.line
        let reply: StubReply? = routes.withLock { routes in
            guard var queue = routes[key], let first = queue.first else { return nil }
            if queue.count > 1 {
                queue.removeFirst()
                routes[key] = queue
            }
            return first
        }
        if reply == nil {
            strays.withLock { $0.append(request) }
        }
        log.withLock { $0.append(request) }
        return reply
    }

    fileprivate func hold(_ held: HeldStream) {
        open.withLock { $0.append(held) }
    }

    fileprivate func release(_ held: HeldStream) {
        open.withLock { $0.removeAll { $0 === held } }
    }
}

/// The protocol a stream is being sent through, kept so a test can send more later.
private final class HeldStream: @unchecked Sendable {
    private let lock = Mutex(false)
    private let client: any URLProtocolClient
    private let source: URLProtocol

    init(client: any URLProtocolClient, source: URLProtocol) {
        self.client = client
        self.source = source
    }

    func send(_ data: Data) {
        lock.withLock { finished in
            if !finished { client.urlProtocol(source, didLoad: data) }
        }
    }

    func finish() {
        lock.withLock { finished in
            if !finished { client.urlProtocolDidFinishLoading(source) }
            finished = true
        }
    }

    /// A whole response, unless the session stopped this protocol first.
    func respond(_ response: URLResponse, _ data: Data) {
        lock.withLock { finished in
            guard !finished else { return }
            client.urlProtocol(source, didReceive: response, cacheStoragePolicy: .notAllowed)
            client.urlProtocol(source, didLoad: data)
            client.urlProtocolDidFinishLoading(source)
            finished = true
        }
    }

    func stop() {
        lock.withLock { $0 = true }
    }
}

/// Every request a test transport makes lands here. It never touches the network: it answers
/// from the `StubServer` registered for the request's host and port, and a request for any other
/// host is kept in `strays` and fails.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    private static let servers = Mutex<[String: StubServer]>([:])
    private static let unknownHosts = Mutex<[Recorded]>([])
    private let held = Mutex<HeldStream?>(nil)
    private let server = Mutex<StubServer?>(nil)

    static func register(_ server: StubServer) {
        servers.withLock { $0[key(server.base)] = server }
    }

    /// Requests to a host no stub server owns.
    static var strays: [Recorded] { unknownHosts.withLock { $0 } }

    private static func key(_ url: URL) -> String {
        "\(url.host(percentEncoded: true) ?? ""):\(url.port ?? -1)"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let client, let url = request.url else { return }
        let recorded = Recorded(
            method: request.httpMethod ?? "GET", url: url,
            headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request))
        guard let owner = Self.servers.withLock({ $0[Self.key(url)] }) else {
            Self.unknownHosts.withLock { $0.append(recorded) }
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        server.withLock { $0 = owner }
        guard let reply = owner.reply(to: recorded) else {
            client.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch reply {
        case .json(let status, let text):
            respond(status, Data(text.utf8), contentType: "application/json")
        case .body(let status, let data, let contentType):
            respond(status, data, contentType: contentType)
        case .redirect(let status, let target):
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1",
                headerFields: ["Location": target.absoluteString, "Content-Length": "0"])!
            // As the system's HTTP loader does: offer the redirect, and if the session declines
            // it, the 30x itself is the answer. A followed redirect stops this protocol first and
            // starts a new request for the target, which the stub would record as a stray.
            client.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            let stream = HeldStream(client: client, source: self)
            held.withLock { $0 = stream }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
                stream.respond(response, Data())
            }
        case .fail(let code):
            client.urlProtocol(self, didFailWithError: URLError(code))
        case .streamStatus(let status):
            respond(status, Data(#"{"error":"unauthorized","message":"Sign in again."}"#.utf8),
                    contentType: "application/json")
        case .events(let chunks, let end):
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"])!
            client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            let stream = HeldStream(client: client, source: self)
            held.withLock { $0 = stream }
            for chunk in chunks { stream.send(Data(chunk.utf8)) }
            if end {
                stream.finish()
            } else {
                owner.hold(stream)
            }
        }
    }

    override func stopLoading() {
        if let stream = held.withLock({ $0 }) {
            stream.stop()
            server.withLock { $0 }?.release(stream)
        }
    }

    private func respond(_ status: Int, _ data: Data, contentType: String) {
        guard let client, let url = request.url else { return }
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": contentType])!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: data)
        client.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// A transport that must never be used. Every request it receives is kept and fails, so a test
/// can say exactly zero requests were made. Only the guards' refusal tests use it.
final class TrapProtocol: URLProtocol, @unchecked Sendable {
    private static let log = Mutex<[Recorded]>([])

    static var requests: [Recorded] { log.withLock { $0 } }
    static let transport = HTTPTransport(protocolClasses: [TrapProtocol.self])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url {
            Self.log.withLock {
                $0.append(Recorded(
                    method: request.httpMethod ?? "GET", url: url,
                    headers: request.allHTTPHeaderFields ?? [:], body: nil))
            }
        }
        client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
    }

    override func stopLoading() {}
}

/// The refusal a call ends in, or nil if it went through.
func clinicRefusal<Value>(_ call: () async throws -> Value) async -> (any Error)? {
    do {
        _ = try await call()
        return nil
    } catch {
        return error
    }
}

/// A fixture's text, for a stub reply.
func fixtureText(_ name: String) throws -> String {
    String(decoding: try Fixture.data(name), as: UTF8.self)
}
