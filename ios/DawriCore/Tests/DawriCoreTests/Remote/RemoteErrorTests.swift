import Foundation
import Testing
@testable import DawriCore

/// `api()` and `toApiError` in frontend/src/api/client.ts, through the stub.
@Suite("Remote: errors as client.ts maps them")
struct RemoteErrorTests {
    @Test func `a backend error keeps its Arabic and the rest as extra`() async throws {
        let server = StubServer()
        server.on("POST", "/api/visits", .json(409, try fixtureText("api_error_ar")))
        let error = await clinicRefusal { try await server.service(token: "t").createVisit(patientId: nil) }
        let clinic = try #require(error as? ClinicError)
        #expect(clinic == ClinicError(status: 409, body: try Fixture.data("api_error_ar")))
        #expect(clinic.code == "emergency_today")
        #expect(clinic.messageAr?.isEmpty == false)
        #expect(clinic.extra["visit_id"] != nil)
    }

    @Test func `an HTML page from a proxy is an internal error with its status`() async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .body(502, Data("<html>Bad gateway</html>".utf8), contentType: "text/html"))
        let error = await clinicRefusal { try await server.service(token: "t").getMe() }
        #expect(error as? ClinicError == ClinicError(
            status: 502, code: "internal_error", message: "Unexpected response from the server."))
    }

    @Test func `a 200 that is not the expected shape is a server fault`() async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .json(200, #"{"nope":1}"#))
        let error = await clinicRefusal { try await server.service(token: "t").getMe() }
        let clinic = try #require(error as? ClinicError)
        #expect(clinic.code == "internal_error")
        #expect(ChatRules.isUnknownOutcome(clinic), "The chat must read the visit to learn what happened")
    }

    @Test(arguments: [URLError.Code.notConnectedToInternet, .timedOut, .cannotConnectToHost, .networkConnectionLost])
    func `a failed connection is the network error and sends the next call through the gate`(
        code: URLError.Code
    ) async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .fail(code), .json(200, try fixtureText("me_with_dependents")))
        let service = try server.service(token: "t")
        let error = await clinicRefusal { try await service.getMe() }
        #expect(error as? ClinicError == .network)
        #expect(ChatRules.isUnknownOutcome(try #require(error)))
        _ = try await service.getMe()
        #expect(server.lines == ["GET /api/health", "GET /api/me", "GET /api/health", "GET /api/me"])
    }

    @Test func `an unreachable health read is the network error`() async throws {
        let server = StubServer()
        server.on("GET", "/api/health", .fail(.cannotConnectToHost))
        let error = await clinicRefusal { try await server.service().demoPatients() }
        #expect(error as? ClinicError == .network)
        #expect(server.lines == ["GET /api/health"])
    }

    @Test func `a 401 unauthorized forgets the token that was sent`() async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .json(401, #"{"error":"unauthorized","message":"Sign in again."}"#))
        let tokens = MemoryTokenStore("old")
        let service = try RemoteClinicService(baseURL: server.base, transport: server.transport, tokens: tokens)
        let error = await clinicRefusal { try await service.getMe() }
        #expect((error as? ClinicError)?.code == "unauthorized")
        #expect((error as? ClinicError)?.status == 401)
        #expect(tokens.load() == nil)
        #expect(await !service.isSignedIn)
    }

    @Test func `invalid_otp is also a 401 and keeps the session`() async throws {
        let server = StubServer()
        server.on("POST", "/api/auth/verify", .json(401, try fixtureText("api_error")))
        let tokens = MemoryTokenStore("kept")
        let service = try RemoteClinicService(baseURL: server.base, transport: server.transport, tokens: tokens)
        let error = await clinicRefusal { try await service.authVerify(qid: "DEMO-10001", otp: "1234") }
        #expect((error as? ClinicError)?.code == "invalid_otp")
        #expect(tokens.load() == "kept")
        #expect(await service.isSignedIn)
    }

    @Test func `a 401 does not clear a token that changed while it was in flight`() async throws {
        let server = StubServer()
        let tokens = MemoryTokenStore("first")
        server.on("GET", "/api/me", .json(401, #"{"error":"unauthorized","message":"x"}"#))
        let service = try RemoteClinicService(baseURL: server.base, transport: server.transport, tokens: tokens)
        // The same rule as client.ts: only the token that was sent is forgotten.
        _ = await clinicRefusal { try await service.getMe() }
        #expect(tokens.load() == nil)
        tokens.save("second")
        server.on("POST", "/api/auth/verify", .json(401, try fixtureText("api_error")))
        _ = await clinicRefusal { try await service.authVerify(qid: "DEMO-10001", otp: "1") }
        #expect(tokens.load() == "second")
    }

    /// The chat's 45 s limit cancels its task, and needs `CancellationError` back.
    @Test(.timeLimit(.minutes(1)))
    func `a cancelled call throws CancellationError`() async throws {
        let server = StubServer()
        // Headers then nothing, so the request never finishes on its own.
        server.on("POST", "/api/visits/V_1/chat", .events([], end: false))
        let service = try server.service(token: "t")
        _ = try await service.health()
        let call = Task { try await service.sendChat(visitId: "V_1", text: "hello") }
        while server.openStreams == 0 { try await Task.sleep(for: .milliseconds(10)) }
        call.cancel()
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
        // A cancellation is not a network failure, so the gate still stands.
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")))
        _ = try await service.getMe()
        #expect(server.lines.suffix(1) == ["GET /api/me"])
    }

    @Test func `a cancelled health read throws CancellationError`() async throws {
        let server = StubServer()
        server.on("GET", "/api/health", .events([], end: false))
        let service = try server.service()
        let call = Task { try await service.demoPatients() }
        while server.openStreams == 0 { try await Task.sleep(for: .milliseconds(10)) }
        call.cancel()
        let result = await call.result
        #expect(throws: CancellationError.self) { try result.get() }
    }
}
