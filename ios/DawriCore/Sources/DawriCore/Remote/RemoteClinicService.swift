import Foundation

/// Clinic server mode: the REST and event-stream API of frontend/src/api/, against a Dawri
/// backend on the local network. Each method is one call from frontend/src/api/endpoints.ts, with
/// the same method, path and body, so the web's staff consoles drive the patient's ticket.
///
/// The second guard lives here. Before its first request, and again after any network failure
/// or ended stream, the service reads `/api/health`. Unless that says `ai_mode: simulated`, every
/// call throws `ClinicError.serverNotSimulated` and nothing else is sent. A server restarted in
/// real mode is therefore refused on the next call after the reconnect.
///
/// Every request is built from the checked base with its scheme, host and port pinned, and is
/// checked against it again before sending. Redirects are never followed. The service has no
/// speech upload: voice is always turned into text on the phone.
///
/// Errors follow `api()` in frontend/src/api/client.ts:
/// - a server reply is `ClinicError(status:body:)`, and `unauthorized` forgets the token that was
///   sent, while `invalid_otp`, also a 401, does not
/// - a failed connection is `ClinicError.network`
/// - a cancelled calling task throws `CancellationError`, which the chat's 45 s limit relies on
public actor RemoteClinicService: ClinicService {
    /// `scheme://host[:port]`, as `ServerAddress` gave it.
    public nonisolated let baseURL: URL
    private let transport: HTTPTransport
    private let tokens: any TokenStore

    /// Whether `/api/health` said simulated since the last failure.
    private var verified = false
    /// Moves on every failure, so a health read that started before one cannot vouch after it.
    private var epoch = 0
    private var streams: [String: [UUID: Task<Void, Never>]] = [:]

    /// - Parameters:
    ///   - baseURL: an address that passed `ServerAddress`, usually `ServerCheck.Connection.baseURL`.
    ///   - transport: the app keeps one for the life of the process.
    ///   - tokens: where the patient's session token is kept.
    /// - Throws: `ServerCheck.Refusal.address` when `baseURL` is not exactly what `ServerAddress`
    ///   gives for it. Nothing is sent.
    public init(baseURL: URL, transport: HTTPTransport, tokens: any TokenStore) throws {
        if let refusal = ServerCheck.refusal(of: baseURL) { throw ServerCheck.Refusal.address(refusal) }
        self.baseURL = baseURL
        self.transport = transport
        self.tokens = tokens
    }

    // The simulated-mode gate

    /// Reads `/api/health` unless it already said simulated since the last failure.
    private func requireSimulated() async throws {
        if verified { return }
        _ = try await readHealth(token: nil)
    }

    /// One health read. Throws unless it says simulated, and records the answer for the gate.
    private func readHealth(token: String?) async throws -> Health {
        let started = epoch
        let reply: ServerCheck.Reply
        do {
            reply = try await ServerCheck.read(base: baseURL, token: token, transport: transport)
        } catch is CancellationError {
            throw CancellationError()
        }
        switch reply {
        case .health(let health):
            if started == epoch { verified = true }
            return health
        case .notSimulated:
            invalidate()
            throw ClinicError.serverNotSimulated
        case .status(let status, let body):
            invalidate()
            throw ClinicError(status: status, body: body)
        case .failed:
            invalidate()
            throw ClinicError.network
        }
    }

    /// The next call reads `/api/health` again first.
    private func invalidate() {
        verified = false
        epoch += 1
    }

    // Requests

    private enum Body {
        case none
        case json(Data)
    }

    private func send(
        _ method: String, _ path: String, query: [(String, String)] = [], body: Body = .none
    ) async throws -> Data {
        try await requireSimulated()
        let token = tokens.load()
        let url = try RemoteRequest.url(base: baseURL, path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if case .json(let data) = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = data
        }
        // Checked again here, at the last moment before sending.
        guard let target = request.url, RemoteRequest.sameOrigin(target, baseURL) else {
            throw RemoteRequest.offHost
        }

        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await transport.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            invalidate()
            throw ClinicError.network
        }
        if (200..<300).contains(response.statusCode) { return data }

        let error = ClinicError(status: response.statusCode, body: data)
        // invalid_otp is also a 401, and it is not the session ending.
        if error.code == "unauthorized", let token, token == tokens.load() { tokens.clear() }
        throw error
    }

    private func call<Reply: Decodable>(
        _ type: Reply.Type, _ method: String, _ path: String, query: [(String, String)] = [],
        body: Body = .none
    ) async throws -> Reply {
        let data = try await send(method, path, query: query, body: body)
        do {
            return try JSONDecoder().decode(Reply.self, from: data)
        } catch {
            throw Self.unreadable
        }
    }

    private func json(_ value: some Encodable) throws -> Body {
        .json(try JSONEncoder().encode(value))
    }

    /// A 2xx whose body is not the shape the web expects. Counted as a server fault, so the chat
    /// reads the visit to learn what happened.
    static let unreadable = ClinicError(
        status: 502, code: "internal_error", message: "Unexpected response from the server.")

    private static func visitPath(_ visitId: String) -> String {
        "/api/visits/\(RemoteRequest.pathSegment(visitId))"
    }

    // ClinicService

    public func authStart(qid: String) async throws -> AuthStartResponse {
        try await call(
            AuthStartResponse.self, "POST", "/api/auth/start", body: json(["qid": qid]))
    }

    public func authVerify(qid: String, otp: String) async throws -> Patient {
        let answer = try await call(
            AuthVerifyResponse.self, "POST", "/api/auth/verify",
            body: json(["qid": qid, "otp": otp]))
        tokens.save(answer.token)
        return answer.patient
    }

    public func demoPatients() async throws -> [DemoPatient] {
        try await call([DemoPatient].self, "GET", "/api/auth/demo-patients")
    }

    /// The gate's own read. It throws `serverNotSimulated` rather than return any other mode.
    public func health() async throws -> Health {
        try await readHealth(token: tokens.load())
    }

    public func getMe() async throws -> Me {
        try await call(Me.self, "GET", "/api/me")
    }

    public func createVisit(patientId: String?) async throws -> CreateVisitResponse {
        try await call(
            CreateVisitResponse.self, "POST", "/api/visits",
            body: json(CreateVisitBody(patientId: patientId)))
    }

    public func listVisits() async throws -> [VisitRow] {
        try await call([VisitRow].self, "GET", "/api/visits")
    }

    public func getVisit(visitId: String) async throws -> Visit {
        try await call(Visit.self, "GET", Self.visitPath(visitId))
    }

    public func sendChat(visitId: String, text: String) async throws -> ChatResponse {
        try await call(
            ChatResponse.self, "POST", Self.visitPath(visitId) + "/chat", body: json(["text": text]))
    }

    public func confirmIntake(visitId: String, service: Service?) async throws -> ConfirmResponse {
        try await call(
            ConfirmResponse.self, "POST", Self.visitPath(visitId) + "/intake/confirm",
            body: json(ConfirmBody(service: service)))
    }

    public func continueRefill(visitId: String) async throws -> ConfirmResponse {
        try await call(ConfirmResponse.self, "POST", Self.visitPath(visitId) + "/refill/continue")
    }

    public func emergencyOverride(visitId: String) async throws -> OverrideResponse {
        try await call(OverrideResponse.self, "POST", Self.visitPath(visitId) + "/emergency/override")
    }

    public func listCentres(
        service: String, visitId: String, lat: Double?, lng: Double?
    ) async throws -> CentreList {
        var query = [("service", service), ("visit_id", visitId)]
        if let lat { query.append(("lat", RemoteRequest.jsNumber(lat))) }
        if let lng { query.append(("lng", RemoteRequest.jsNumber(lng))) }
        return try await call(CentreList.self, "GET", "/api/centres", query: query)
    }

    public func reserve(visitId: String, centreId: String) async throws -> ReserveResponse {
        try await call(
            ReserveResponse.self, "POST", Self.visitPath(visitId) + "/reserve",
            body: json(["centre_id": centreId]))
    }

    public func arrive(visitId: String, body: ArriveBody) async throws -> ArriveResponse {
        try await call(
            ArriveResponse.self, "POST", Self.visitPath(visitId) + "/arrive", body: json(body))
    }

    public func rateVisit(visitId: String, stars: Int) async throws -> RatingResponse {
        try await call(
            RatingResponse.self, "POST", Self.visitPath(visitId) + "/rating",
            body: json(["stars": stars]))
    }

    public var isSignedIn: Bool { tokens.load() != nil }

    /// Forgets the token. The server's session is left to expire, as on the web.
    public func signOut() {
        tokens.clear()
    }

    // Live updates

    /// `GET /api/visits/{id}/stream`, with the token in the Authorization header rather than the
    /// URL the web's EventSource needs.
    ///
    /// Yields `.open` on a 200, `.changed` for each event with data, and `.dropped` last, after a
    /// refusal, a status other than 200, a failure, the end of the stream or a cancellation.
    /// Comments such as the 15 s heartbeat give nothing. An ended stream sends the next call
    /// through the health gate again.
    public func visitUpdates(visitId: String) async -> AsyncStream<VisitUpdate> {
        let (stream, continuation) = AsyncStream.makeStream(of: VisitUpdate.self)
        let id = UUID()
        let task = Task {
            await self.follow(visitId: visitId, continuation: continuation)
            self.forget(visitId: visitId, id: id)
            continuation.yield(.dropped)
            continuation.finish()
        }
        streams[visitId, default: [:]][id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private func follow(
        visitId: String, continuation: AsyncStream<VisitUpdate>.Continuation
    ) async {
        defer { invalidate() }
        guard (try? await requireSimulated()) != nil, !Task.isCancelled,
              let url = try? RemoteRequest.url(base: baseURL, path: Self.visitPath(visitId) + "/stream"),
              RemoteRequest.sameOrigin(url, baseURL)
        else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let token = tokens.load() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        await Self.read(request, transport: transport, into: continuation)
    }

    /// Off the actor, so reading bytes never waits behind a request.
    private nonisolated static func read(
        _ request: URLRequest, transport: HTTPTransport,
        into continuation: AsyncStream<VisitUpdate>.Continuation
    ) async {
        do {
            let (bytes, response) = try await transport.stream(for: request)
            guard response.statusCode == 200 else { return }
            continuation.yield(.open)
            var parser = EventStreamParser()
            for try await byte in bytes {
                if parser.push(byte) != nil { continuation.yield(.changed) }
            }
        } catch {
            // A failure or a cancellation ends the stream the same way: `.dropped`.
        }
    }

    private func forget(visitId: String, id: UUID) {
        streams[visitId]?[id] = nil
        if streams[visitId]?.isEmpty == true { streams[visitId] = nil }
    }

    /// Ends the streams on one visit, or on all of them, the way a lost connection would.
    func dropStreams(visitId: String? = nil) {
        let ids = visitId.map { [$0] } ?? Array(streams.keys)
        for id in ids {
            for task in (streams[id] ?? [:]).values { task.cancel() }
        }
    }
}

// Bodies, each as endpoints.ts sends it.

/// `{consent: true, patient_id?}`. A nil patient leaves the key out.
private struct CreateVisitBody: Encodable {
    let consent = true
    let patientId: String?

    enum CodingKeys: String, CodingKey {
        case consent
        case patientId = "patient_id"
    }
}

/// `{json: {service}}` with a service, else `{}`.
private struct ConfirmBody: Encodable {
    let service: Service?

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        if let service {
            var answers = container.nestedContainer(keyedBy: Key.self, forKey: .json)
            try answers.encode(service, forKey: .service)
        }
    }

    enum Key: String, CodingKey {
        case json, service
    }
}
