import Foundation
import Testing
@testable import DawriCore

// The two guards of Clinic server mode, the product's promise that this app cannot spend
// credits. Every request goes through a recording stub, so nothing here reaches a network, and
// a refusal is proved by what the stub did not receive.
//
// No-credit allowlist: this file names Hugging Face hosts and the speech path on purpose, as
// the forms that must be refused and the path that must never appear.

private struct Typed: Sendable, CustomTestStringConvertible {
    let text: String
    var testDescription: String { text.debugDescription }
    init(_ text: String) { self.text = text }
}

/// Every form of a Hugging Face host: sub-domain, the bare names, upper case, trailing dot, user
/// info, port and hf.co.
private let huggingFace: [Typed] = [
    "https://dawri.hf.space", "https://xtamim-dawri.hf.space", "https://hf.space",
    "https://huggingface.co", "https://www.huggingface.co", "https://router.huggingface.co",
    "https://api-inference.huggingface.co",
    "HTTPS://DAWRI.HF.SPACE", "https://HuggingFace.CO", "HTTPS://HF.CO",
    "https://dawri.hf.space.", "https://huggingface.co.", "https://hf.co.",
    "https://user@dawri.hf.space", "https://user:pass@huggingface.co", "http://127.0.0.1@dawri.hf.space",
    "https://dawri.hf.space:443", "https://huggingface.co:8443", "http://dawri.hf.space:8100",
    "https://hf.co", "https://api.hf.co", "https://me@hf.co:443/",
    "  HTTPS://Admin:Secret@Dawri.HF.Space.:443/  ", "dawri.hf.space", "huggingface.co",
].map(Typed.init)

/// `http` to a host that is not on the local network.
private let publicHTTP: [Typed] = [
    "http://example.com", "http://example.com:8100", "http://8.8.8.8", "http://8.8.8.8:8100",
    "http://dawri.example.org/", "http://172.32.0.1:8100", "http://192.169.1.1",
].map(Typed.init)

/// The modes `/api/health` can report that are not `simulated`.
private let notSimulated = ["real", "REAL", "Simulated", "simulated ", "unknown", ""]

/// One of each call, so the gate is seen to cover all of them.
private let everyCall: [(String, @Sendable (RemoteClinicService) async throws -> Void)] = [
    ("authStart", { _ = try await $0.authStart(qid: "DEMO-10001") }),
    ("authVerify", { _ = try await $0.authVerify(qid: "DEMO-10001", otp: "0000") }),
    ("demoPatients", { _ = try await $0.demoPatients() }),
    ("health", { _ = try await $0.health() }),
    ("getMe", { _ = try await $0.getMe() }),
    ("createVisit", { _ = try await $0.createVisit(patientId: nil) }),
    ("listVisits", { _ = try await $0.listVisits() }),
    ("getVisit", { _ = try await $0.getVisit(visitId: "V_1") }),
    ("sendChat", { _ = try await $0.sendChat(visitId: "V_1", text: "hi") }),
    ("confirmIntake", { _ = try await $0.confirmIntake(visitId: "V_1", service: nil) }),
    ("continueRefill", { _ = try await $0.continueRefill(visitId: "V_1") }),
    ("emergencyOverride", { _ = try await $0.emergencyOverride(visitId: "V_1") }),
    ("listCentres", { _ = try await $0.listCentres(service: "gp", visitId: "V_1", lat: nil, lng: nil) }),
    ("reserve", { _ = try await $0.reserve(visitId: "V_1", centreId: "C-WAKRA") }),
    ("arrive", { _ = try await $0.arrive(visitId: "V_1", body: .button) }),
    ("rateVisit", { _ = try await $0.rateVisit(visitId: "V_1", stars: 5) }),
]

@Suite("Credit guard 1: no Hugging Face host and no public http, with zero requests")
struct HostGuardTests {
    @Test(arguments: huggingFace)
    fileprivate func `a Hugging Face host is refused before any request`(typed: Typed) async throws {
        let error = await clinicRefusal {
            try await ServerCheck.connect(to: typed.text, transport: TrapProtocol.transport)
        }
        #expect(error as? ServerCheck.Refusal == .address(.forbiddenHost))
        #expect(TrapProtocol.requests.isEmpty, "\(TrapProtocol.requests)")
    }

    @Test(arguments: huggingFace)
    fileprivate func `neither the health check nor the service takes one as a base`(typed: Typed) async {
        // However it is spelt as a URL, it never passes as a base.
        guard let url = URL(string: typed.text.trimmingCharacters(in: .whitespaces)) else { return }
        let health = await clinicRefusal { try await ServerCheck.health(at: url, transport: TrapProtocol.transport) }
        guard case .address? = health as? ServerCheck.Refusal else {
            Issue.record("Not refused as an address: \(String(describing: health))")
            return
        }
        #expect(throws: ServerCheck.Refusal.self) {
            try RemoteClinicService(baseURL: url, transport: TrapProtocol.transport, tokens: MemoryTokenStore())
        }
        #expect(TrapProtocol.requests.isEmpty, "\(TrapProtocol.requests)")
    }

    @Test(arguments: publicHTTP)
    fileprivate func `http to a public host is refused before any request`(typed: Typed) async throws {
        let error = await clinicRefusal {
            try await ServerCheck.connect(to: typed.text, transport: TrapProtocol.transport)
        }
        #expect(error as? ServerCheck.Refusal == .address(.insecure))
        let url = try #require(URL(string: typed.text))
        #expect(throws: ServerCheck.Refusal.self) {
            try RemoteClinicService(baseURL: url, transport: TrapProtocol.transport, tokens: MemoryTokenStore())
        }
        #expect(TrapProtocol.requests.isEmpty, "\(TrapProtocol.requests)")
    }

    /// The same check does reach a local server, so the zeros above are refusals, not a check
    /// that never sends anything.
    @Test func `a local simulated server passes after one health read`() async throws {
        let server = StubServer()
        let connection = try await ServerCheck.connect(to: server.base.absoluteString, transport: server.transport)
        #expect(connection.baseURL == server.base)
        #expect(connection.health.aiMode == .simulated)
        #expect(server.lines == ["GET /api/health"])
    }
}

@Suite("Credit guard 2: simulated mode only")
struct SimulatedGuardTests {
    @Test(arguments: notSimulated)
    func `the check refuses any other mode after one health read`(mode: String) async throws {
        let server = StubServer(health: mode)
        let error = await clinicRefusal {
            try await ServerCheck.connect(to: server.base.absoluteString, transport: server.transport)
        }
        #expect(error as? ServerCheck.Refusal == .notSimulated(AiMode(rawValue: mode)))
        #expect(server.lines == ["GET /api/health"])
        server.expectNoSurprises()
    }

    @Test(arguments: ["{}", #"{"status":"ok"}"#, "<html>router</html>", #"{"ai_mode":7}"#])
    func `an answer that is not a health reply is refused`(body: String) async throws {
        let server = StubServer()
        server.on("GET", "/api/health", .json(200, body))
        let error = await clinicRefusal {
            try await ServerCheck.connect(to: server.base.absoluteString, transport: server.transport)
        }
        #expect(error as? ServerCheck.Refusal == .notSimulated(nil))
        #expect(server.lines == ["GET /api/health"])
    }

    @Test(arguments: ["real", "unknown"], 0..<everyCall.count)
    func `every call of the service is refused after exactly one health read`(
        mode: String, index: Int
    ) async throws {
        let server = StubServer(health: mode)
        let (name, call) = everyCall[index]
        let error = await clinicRefusal { try await call(try server.service(token: "t")) }
        #expect(error as? ClinicError == .serverNotSimulated, "\(name)")
        #expect((error as? ClinicError)?.code == "server_not_simulated")
        #expect(server.lines == ["GET /api/health"], "\(name)")
        server.expectNoSurprises()
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["real", "unknown"])
    func `the stream is refused after exactly one health read`(mode: String) async throws {
        let server = StubServer(health: mode)
        var seen: [VisitUpdate] = []
        for await update in try await server.service(token: "t").visitUpdates(visitId: "V_1") {
            seen.append(update)
        }
        #expect(seen == [.dropped])
        #expect(server.lines == ["GET /api/health"])
    }

    @Test func `the refusal reads plainly in both languages`() {
        let strings = Strings.bundled
        let error = ClinicError.serverNotSimulated
        #expect(errorText(error, strings: strings, lang: .en) == strings.translate(.en, "settings.server.refusedAi"))
        #expect(errorText(error, strings: strings, lang: .ar) == strings.translate(.ar, "settings.server.refusedAi"))
        #expect(!ChatRules.isUnknownOutcome(error), "Nothing was sent, so the outcome is known")
    }

    @Test(arguments: [301, 302, 303, 307, 308])
    func `a redirect from health to another host is not followed`(status: Int) async throws {
        let server = StubServer()
        let elsewhere = URL(string: "https://elsewhere-\(status)-\(UUID().uuidString.prefix(8)).example/api/health")!
        server.on("GET", "/api/health", .redirect(status, elsewhere))

        let check = await clinicRefusal {
            try await ServerCheck.connect(to: server.base.absoluteString, transport: server.transport)
        }
        #expect(check as? ServerCheck.Refusal == .unreachable)
        let call = await clinicRefusal { try await server.service(token: "t").getMe() }
        #expect(call is ClinicError)
        #expect(server.lines == ["GET /api/health", "GET /api/health"])
        #expect(!StubProtocol.strays.contains { $0.url.host() == elsewhere.host() })
        server.expectNoSurprises()
    }

    @Test func `a server that turns real is refused on the next call after a failure`() async throws {
        let server = StubServer()
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")), .fail(.networkConnectionLost))
        let service = try server.service(token: "t")
        _ = try await service.getMe()
        // The server goes away, and comes back in real mode.
        #expect(await clinicRefusal { try await service.getMe() } as? ClinicError == .network)
        server.on("GET", "/api/health", .health("real"))
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")))
        #expect(await clinicRefusal { try await service.getMe() } as? ClinicError == .serverNotSimulated)
        #expect(await clinicRefusal { try await service.listVisits() } as? ClinicError == .serverNotSimulated)
        #expect(server.lines == [
            "GET /api/health", "GET /api/me", "GET /api/me", "GET /api/health", "GET /api/health",
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func `a server that turns real is refused after its stream drops`() async throws {
        let server = StubServer()
        server.on("GET", "/api/visits/V_1/stream", .events([": connected\n\n"], end: false))
        let service = try server.service(token: "t")
        var updates = await service.visitUpdates(visitId: "V_1").makeAsyncIterator()
        #expect(await updates.next() == .open)
        // A restart: the stream ends, and the new process is in real mode.
        server.on("GET", "/api/health", .health("real"))
        server.endStreams()
        #expect(await updates.next() == .dropped)
        #expect(await clinicRefusal { try await service.getVisit(visitId: "V_1") } as? ClinicError
            == .serverNotSimulated)
        var again: [VisitUpdate] = []
        for await update in await service.visitUpdates(visitId: "V_1") { again.append(update) }
        #expect(again == [.dropped])
        #expect(server.lines == [
            "GET /api/health", "GET /api/visits/V_1/stream", "GET /api/health", "GET /api/health",
        ])
    }

    /// A whole visit, scripted on the stub: every call the app makes, and never the speech path.
    @Test(.timeLimit(.minutes(1)))
    func `a full scripted journey never asks for speech`() async throws {
        let server = StubServer()
        let created = try Fixture.decode(CreateVisitResponse.self, "create_visit").visitId
        let visit = "/api/visits/\(RemoteRequest.pathSegment(created))"
        server.on("GET", "/api/auth/demo-patients", .json(200, try fixtureText("demo_patients")))
        server.on("POST", "/api/auth/start", .json(200, try fixtureText("auth_start")))
        server.on("POST", "/api/auth/verify", .json(200, try fixtureText("auth_verify")))
        server.on("GET", "/api/me", .json(200, try fixtureText("me_with_dependents")))
        server.on("POST", "/api/visits", .json(200, try fixtureText("create_visit")))
        server.on("POST", "\(visit)/chat", .json(200, try fixtureText("chat_turn")),
                  .json(200, try fixtureText("chat_intake_done")))
        server.on("POST", "\(visit)/intake/confirm", .json(200, try fixtureText("confirm")))
        server.on("GET", "/api/centres", .json(200, try fixtureText("centre_list")))
        server.on("POST", "\(visit)/reserve", .json(200, try fixtureText("reserve")))
        server.on("POST", "\(visit)/arrive", .json(200, try fixtureText("arrive")))
        server.on("GET", visit, .json(200, try fixtureText("visit_triage")),
                  .json(200, try fixtureText("visit_completed")))
        server.on("GET", "\(visit)/stream", .events([": connected\n\n", "data: {}\n\n"], end: true))
        server.on("POST", "\(visit)/rating", .json(200, try fixtureText("rating")))
        server.on("GET", "/api/visits", .json(200, try fixtureText("visit_rows")))

        let service = try server.service()
        _ = try await service.health()
        _ = try await service.demoPatients()
        _ = try await service.authStart(qid: "DEMO-10001")
        _ = try await service.authVerify(qid: "DEMO-10001", otp: "0000")
        _ = try await service.getMe()
        let id = try await service.createVisit(patientId: nil).visitId
        #expect(id == created)
        for line in ["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"] {
            _ = try await service.sendChat(visitId: id, text: line)
        }
        _ = try await service.confirmIntake(visitId: id, service: nil)
        _ = try await service.listCentres(service: "gp", visitId: id, lat: 25.2, lng: 51.5)
        _ = try await service.reserve(visitId: id, centreId: "C-WAKRA")
        _ = try await service.arrive(visitId: id, body: .qrCode("DOOR-C-WAKRA"))
        var updates: [VisitUpdate] = []
        for await update in await service.visitUpdates(visitId: id) { updates.append(update) }
        #expect(updates == [.open, .changed, .dropped])
        _ = try await service.getVisit(visitId: id)
        _ = try await service.getVisit(visitId: id)
        _ = try await service.rateVisit(visitId: id, stars: 5)
        _ = try await service.listVisits()
        await service.signOut()

        let paths = server.requests.map(\.path)
        #expect(paths.count >= 20)
        #expect(!paths.contains { $0.contains("/api/asr") })
        #expect(!paths.contains { $0.lowercased().contains("asr") })
        #expect(server.requests.allSatisfy { $0.url.host() == server.base.host() && $0.url.port == 8100 })
        server.expectNoSurprises()
    }

    @Test func `the service has no speech upload`() throws {
        let source = try Repo.text("ios/DawriCore/Sources/DawriCore/Service/ClinicService.swift")
        #expect(!source.contains("func transcribe"))
        let remote = try FileManager.default.contentsOfDirectory(
            atPath: Repo.root.appending(path: "ios/DawriCore/Sources/DawriCore/Remote").path)
        for file in remote {
            let text = try Repo.text("ios/DawriCore/Sources/DawriCore/Remote/\(file)")
            #expect(!text.contains("/api/asr"), "\(file)")
            #expect(!text.lowercased().contains("transcribe"), "\(file)")
            #expect(!text.contains("multipart"), "\(file)")
        }
    }
}
