import Foundation
import Testing
@testable import DawriCore

private let visitId = "V_0123abcd"
private let token = "tok-123"

/// One call of `RemoteClinicService`, what it must send, and the fixture it is answered with.
/// The expected method, path, query and body are written out from frontend/src/api/endpoints.ts.
private struct Endpoint: Sendable, CustomTestStringConvertible {
    let name: String
    let method: String
    let path: String
    let query: String?
    /// The JSON body, or nil for none at all.
    let body: String?
    let fixture: String
    /// Calls the service and checks the answer against the fixture.
    let run: @Sendable (RemoteClinicService) async throws -> Void

    var testDescription: String { name }

    init<Answer: Decodable & Equatable & Sendable>(
        _ name: String, _ method: String, _ path: String, query: String? = nil, body: String? = nil,
        fixture: String, expecting: @escaping @Sendable (Data) throws -> Answer = {
            try JSONDecoder().decode(Answer.self, from: $0)
        },
        _ call: @escaping @Sendable (RemoteClinicService) async throws -> Answer
    ) {
        self.name = name
        self.method = method
        self.path = path
        self.query = query
        self.body = body
        self.fixture = fixture
        self.run = { service in
            let answer = try await call(service)
            #expect(answer == (try expecting(try Fixture.data(fixture))), "\(name)")
        }
    }
}

private let visit = "/api/visits/\(visitId)"

private let endpoints: [Endpoint] = {
    var all: [Endpoint] = [
        Endpoint(
            "authStart", "POST", "/api/auth/start", body: #"{"qid":"DEMO-10001"}"#,
            fixture: "auth_start"
        ) { try await $0.authStart(qid: "DEMO-10001") },
        Endpoint(
            "authVerify", "POST", "/api/auth/verify", body: #"{"qid":"DEMO-10001","otp":"0000"}"#,
            fixture: "auth_verify",
            expecting: { try JSONDecoder().decode(AuthVerifyResponse.self, from: $0).patient }
        ) { try await $0.authVerify(qid: "DEMO-10001", otp: "0000") },
        Endpoint("demoPatients", "GET", "/api/auth/demo-patients", fixture: "demo_patients") {
            try await $0.demoPatients()
        },
        Endpoint("health", "GET", "/api/health", fixture: "health") { try await $0.health() },
        Endpoint("getMe with dependents", "GET", "/api/me", fixture: "me_with_dependents") {
            try await $0.getMe()
        },
        Endpoint("getMe without dependents", "GET", "/api/me", fixture: "me_no_dependents") {
            try await $0.getMe()
        },
        Endpoint(
            "createVisit for the holder", "POST", "/api/visits", body: #"{"consent":true}"#,
            fixture: "create_visit"
        ) { try await $0.createVisit(patientId: nil) },
        Endpoint(
            "createVisit for a dependent", "POST", "/api/visits",
            body: #"{"consent":true,"patient_id":"P004"}"#, fixture: "create_visit"
        ) { try await $0.createVisit(patientId: "P004") },
        Endpoint("listVisits", "GET", "/api/visits", fixture: "visit_rows") {
            try await $0.listVisits()
        },
        Endpoint(
            "confirmIntake with no answers", "POST", "\(visit)/intake/confirm", body: "{}",
            fixture: "confirm"
        ) { try await $0.confirmIntake(visitId: visitId, service: nil) },
        Endpoint(
            "confirmIntake with a service", "POST", "\(visit)/intake/confirm",
            body: #"{"json":{"service":"womens_health"}}"#, fixture: "confirm"
        ) { try await $0.confirmIntake(visitId: visitId, service: .womensHealth) },
        Endpoint(
            "continueRefill", "POST", "\(visit)/refill/continue", fixture: "confirm_refill_continue"
        ) { try await $0.continueRefill(visitId: visitId) },
        Endpoint("emergencyOverride", "POST", "\(visit)/emergency/override", fixture: "override") {
            try await $0.emergencyOverride(visitId: visitId)
        },
        Endpoint(
            "listCentres", "GET", "/api/centres", query: "service=gp&visit_id=\(visitId)",
            fixture: "centre_list"
        ) { try await $0.listCentres(service: "gp", visitId: visitId, lat: nil, lng: nil) },
        Endpoint(
            "listCentres located", "GET", "/api/centres",
            query: "service=mental_health&visit_id=\(visitId)&lat=25.2&lng=51",
            fixture: "centre_list_fallback"
        ) {
            try await $0.listCentres(service: "mental_health", visitId: visitId, lat: 25.2, lng: 51)
        },
        Endpoint(
            "listCentres with a suggestion", "GET", "/api/centres",
            query: "service=gp&visit_id=\(visitId)&lat=-0.5", fixture: "centre_list_suggestion"
        ) { try await $0.listCentres(service: "gp", visitId: visitId, lat: -0.5, lng: nil) },
        Endpoint(
            "reserve", "POST", "\(visit)/reserve", body: #"{"centre_id":"C-WAKRA"}"#,
            fixture: "reserve"
        ) { try await $0.reserve(visitId: visitId, centreId: "C-WAKRA") },
        Endpoint("arrive by button", "POST", "\(visit)/arrive", body: #"{"button":true}"#, fixture: "arrive") {
            try await $0.arrive(visitId: visitId, body: .button)
        },
        Endpoint(
            "arrive by location", "POST", "\(visit)/arrive", body: #"{"lat":25.17302,"lng":51.59575}"#,
            fixture: "arrive"
        ) { try await $0.arrive(visitId: visitId, body: .location(lat: 25.17302, lng: 51.59575)) },
        Endpoint(
            "arrive by door code", "POST", "\(visit)/arrive", body: #"{"qr_code":"DOOR-C-WAKRA"}"#,
            fixture: "arrive"
        ) { try await $0.arrive(visitId: visitId, body: .qrCode("DOOR-C-WAKRA")) },
        Endpoint("rateVisit", "POST", "\(visit)/rating", body: #"{"stars":4}"#, fixture: "rating") {
            try await $0.rateVisit(visitId: visitId, stars: 4)
        },
    ]
    for name in ["chat_turn", "chat_intake_done", "chat_emergency", "chat_refill"] {
        all.append(Endpoint(
            "sendChat → \(name)", "POST", "\(visit)/chat", body: #"{"text":"عندي حرارة"}"#,
            fixture: name
        ) { try await $0.sendChat(visitId: visitId, text: "عندي حرارة") })
    }
    return all + visitFixtures.map { name in
        Endpoint("getVisit → \(name)", "GET", visit, fixture: name) {
            try await $0.getVisit(visitId: visitId)
        }
    }
}()

/// Every exported `Visit` fixture, found on disk so a new export is covered without an edit.
private let visitFixtures: [String] = {
    let folder = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
    return names.filter { $0.hasPrefix("visit_") && $0.hasSuffix(".json") && $0 != "visit_rows.json" }
        .map { String($0.dropLast(5)) }.sorted()
}()

@Suite("Remote: each endpoint as endpoints.ts sends it")
struct RemoteEndpointTests {
    @Test(arguments: endpoints)
    fileprivate func `method, path, query, headers and body`(endpoint: Endpoint) async throws {
        let server = StubServer()
        server.on(endpoint.method, endpoint.path, .json(200, try fixtureText(endpoint.fixture)))
        let service = try server.service(token: token)
        try await endpoint.run(service)

        // The gate's health read comes first, then the call itself and nothing else.
        let expected = endpoint.path == "/api/health"
            ? ["GET /api/health"] : ["GET /api/health", "\(endpoint.method) \(endpoint.path)"]
        #expect(server.lines == expected)
        let sent = try #require(server.last)
        #expect(sent.url.scheme == "http")
        #expect(sent.url.host() == server.base.host())
        #expect(sent.url.port == 8100)
        #expect(sent.query == endpoint.query)
        #expect(sent.header("Authorization") == "Bearer \(token)")
        #expect(sent.header("Accept") == "application/json")
        if let body = endpoint.body {
            #expect(sent.header("Content-Type") == "application/json")
            #expect(sent.json == (try decode(JSONValue.self, json: body)))
        } else {
            #expect(sent.header("Content-Type") == nil)
            #expect(sent.body == nil || sent.body?.isEmpty == true)
        }
        // The token is only ever in the header.
        #expect(!sent.url.absoluteString.contains(token))
        server.expectNoSurprises()
    }

    @Test func `every exported fixture is answered through some endpoint`() throws {
        let folder = try Fixture.folder
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
        let covered = Set(endpoints.map(\.fixture)).union(["api_error", "api_error_ar"])
        #expect(Set(names).subtracting(covered).isEmpty, "\(Set(names).subtracting(covered))")
        #expect(visitFixtures.count >= 15)
    }

    @Test func `with no token there is no Authorization header`() async throws {
        let server = StubServer()
        server.on("GET", "/api/auth/demo-patients", .json(200, try fixtureText("demo_patients")))
        let service = try server.service()
        #expect(await !service.isSignedIn)
        _ = try await service.demoPatients()
        #expect(server.requests.allSatisfy { $0.header("Authorization") == nil })
    }

    @Test func `the gate's own read sends no token`() async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")))
        _ = try await server.service(token: token).getMe()
        #expect(server.requests.first?.line == "GET /api/health")
        #expect(server.requests.first?.header("Authorization") == nil)
    }

    @Test func `the health gate runs once until something fails`() async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")))
        let service = try server.service(token: token)
        for _ in 0..<3 { _ = try await service.getMe() }
        #expect(server.lines == ["GET /api/health", "GET /api/me", "GET /api/me", "GET /api/me"])
    }

    @Test func `authVerify keeps the token and the next call sends it`() async throws {
        let server = StubServer()
        server.on("POST", "/api/auth/verify", .json(200, try fixtureText("auth_verify")))
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")))
        let service = try server.service()
        let patient = try await service.authVerify(qid: "DEMO-10001", otp: "0000")
        #expect(patient.id == "P001")
        #expect(await service.isSignedIn)
        _ = try await service.getMe()
        let wire = try Fixture.decode(AuthVerifyResponse.self, "auth_verify")
        #expect(server.last?.header("Authorization") == "Bearer \(wire.token)")

        await service.signOut()
        #expect(await !service.isSignedIn)
        server.on("GET", "/api/me", .json(401, #"{"error":"unauthorized","message":"Sign in."}"#))
        _ = await clinicRefusal { try await service.getMe() }
        #expect(server.last?.header("Authorization") == nil)
    }

    /// `encodeURIComponent`: a visit id stays one path segment, whatever it holds.
    @Test func `a visit id is one encoded path segment`() async throws {
        let server = StubServer()
        let odd = "V_1/../../x?y#z é"
        let encoded = "/api/visits/V_1%2F..%2F..%2Fx%3Fy%23z%20%C3%A9"
        server.on("GET", encoded, .json(200, try fixtureText("visit_intake")))
        _ = try await server.service(token: token).getVisit(visitId: odd)
        #expect(server.lines == ["GET /api/health", "GET \(encoded)"])
        #expect(server.last?.url.host() == server.base.host())
        #expect(server.last?.query == nil)
    }

    @Test func `the query is URLSearchParams form encoding`() {
        #expect(RemoteRequest.formQuery([("service", "a b&c=d/é*-._~")])
            == "service=a+b%26c%3Dd%2F%C3%A9*-._%7E")
        #expect(RemoteRequest.pathSegment("a b!~*'()-_.") == "a%20b!~*'()-_.")
    }

    @Test(arguments: [
        (25.2, "25.2"), (51.0, "51"), (-0.0, "0"), (25.17302, "25.17302"), (-122.5, "-122.5"),
        (1e-7, "1e-07"),
    ])
    func `coordinates read as JavaScript writes them`(value: Double, text: String) {
        // Only the last differs in form from JavaScript's 1e-7, and the backend reads both.
        #expect(RemoteRequest.jsNumber(value) == text)
    }

    @Test func `a URL is only built on the base's own origin`() throws {
        let base = URL(string: "http://[::1]:8123")!
        let url = try RemoteRequest.url(base: base, path: "/api/health")
        #expect(url.absoluteString == "http://[::1]:8123/api/health")
        #expect(RemoteRequest.sameOrigin(url, base))
        #expect(!RemoteRequest.sameOrigin(URL(string: "http://[::2]:8123/api/health")!, base))
        #expect(!RemoteRequest.sameOrigin(URL(string: "http://[::1]:8124/api/health")!, base))
        #expect(!RemoteRequest.sameOrigin(URL(string: "https://[::1]:8123/api/health")!, base))
        #expect(!RemoteRequest.sameOrigin(URL(string: "http://u@[::1]:8123/api/health")!, base))
    }

    @Test(arguments: [
        "http://127.0.0.1:8100/api", "http://127.0.0.1:8100/", "http://u@127.0.0.1:8100",
        "http://127.0.0.1:8100?x=1", "ftp://127.0.0.1", "http://example.com",
    ])
    func `the service only takes a base ServerAddress gave`(text: String) {
        #expect(throws: ServerCheck.Refusal.self) {
            try RemoteClinicService(
                baseURL: URL(string: text)!, transport: TrapProtocol.transport,
                tokens: MemoryTokenStore())
        }
    }
}
