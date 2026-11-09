import Foundation
import SQLite3
import Testing
@testable import DawriCore

/// Clinic server mode, against a real Dawri backend in simulated mode on this Mac. Only
/// ios/Tools/clinic-server.sh starts one, with a blank HF_TOKEN, on 127.0.0.1 and a temp
/// database, and it sets the two variables this reads:
///
/// - `DAWRI_CONTRACT_SERVER`: `http://127.0.0.1:<port>`, and nothing else
/// - `DAWRI_CONTRACT_DB`: that server's temp SQLite file
///
/// Staff move the ticket through the real staff API, as the helpers in
/// backend/tests/test_api_e2e.py do. Nothing here tells the suite which back end it has.
final class RemoteHarness: ContractHarness {
    let base: URL
    let database: String
    private let transport = HTTPTransport()

    var testDescription: String { "clinic server" }

    private init(base: URL, database: String) {
        self.base = base
        self.database = database
    }

    /// The harness the environment asks for, or nil when it asks for none. A malformed request
    /// stops the run, so a typo can never send the suite somewhere else.
    static func fromEnvironment() -> RemoteHarness? {
        let environment = ProcessInfo.processInfo.environment
        guard let text = environment["DAWRI_CONTRACT_SERVER"] else { return nil }
        guard let match = text.wholeMatch(of: #/http://127\.0\.0\.1:([0-9]{2,5})/#),
              let port = Int(match.output.1), (1...65_535).contains(port),
              let url = URL(string: text), ServerAddress.parse(text) == .ok(url)
        else {
            fatalError("DAWRI_CONTRACT_SERVER must be http://127.0.0.1:<port>, not \(text.debugDescription)")
        }
        guard let database = environment["DAWRI_CONTRACT_DB"], database.hasSuffix(".db"),
              FileManager.default.fileExists(atPath: database),
              !database.contains("backend/data")
        else {
            fatalError("DAWRI_CONTRACT_DB must name the contract server's temp database")
        }
        return RemoteHarness(base: url, database: database)
    }

    private func remote(_ service: any ClinicService) throws -> RemoteClinicService {
        try #require(service as? RemoteClinicService)
    }

    // ContractHarness

    func makeService() async throws -> any ClinicService {
        // The simulated-mode guard first: nothing else is sent to a server that fails it.
        let health = try await ServerCheck.health(at: base, transport: transport)
        try #require(health.aiMode == .simulated)
        let nurse = try await login("S-WAK-NURSE1")
        let reset = try await staff("POST", "/api/demo/reset", token: nurse.token)
        try #require(reset["ok"] == .bool(true))
        return try RemoteClinicService(baseURL: base, transport: transport, tokens: MemoryTokenStore())
    }

    /// One stage per call: triage to the doctor, the doctor to pharmacy, pharmacy to done.
    func moveToNextStage(_ service: any ClinicService, visitId: String) async throws {
        let visit = try await service.getVisit(visitId: visitId)
        let path = "/api/visits/\(RemoteRequest.pathSegment(visitId))"
        switch visit.stage {
        case .triage:
            let nurse = try await login("S-WAK-NURSE1")
            try await callNext(nurse, expecting: visitId)
            _ = try await staff("POST", "\(path)/vitals", token: nurse.token, body: [
                "bp_sys": 120, "bp_dia": 80, "hr": 72, "temp_c": 38.1, "spo2": 98, "urgency": "routine",
            ])
            let draft = try await staff("POST", "\(path)/handoff/draft", token: nurse.token)
            guard case .string(let text)? = draft["text"],
                  case .array(let suggestions)? = draft["suggestions"],
                  case .string(let doctor)? = suggestions.first?["doctor_id"]
            else {
                Issue.record("The handoff draft has no text or suggestion: \(draft)")
                return
            }
            _ = try await staff("POST", "\(path)/handoff/confirm", token: nurse.token, body: [
                "final_text": .string(text), "doctor_id": .string(doctor),
            ])
        case .doctor:
            let counter = try #require(visit.ticket?.counterId)
            let doctor = try await doctorAt(counter)
            try await callNext(doctor, counter: counter, expecting: visitId)
            // PRESCRIPTION in test_api_e2e.py: nothing a penicillin allergy conflicts with.
            _ = try await staff("POST", "\(path)/consult/done", token: doctor.token, body: [
                "prescription": [["drug_id": "DR-PARA"], ["drug_id": "DR-DEXT"]],
            ])
        case .pharmacy:
            let pharmacist = try await login("S-WAK-PHARM1")
            try await callNext(pharmacist, expecting: visitId)
            _ = try await staff("POST", "\(path)/dispensed", token: pharmacist.token)
        default:
            Issue.record("No staff step moves a visit on from \(visit.stage)")
        }
    }

    func dropUpdates(_ service: any ClinicService, visitId: String) async throws {
        try await remote(service).dropStreams(visitId: visitId)
    }

    /// Moves the stored stamp back 46 minutes, in the backend's own format, on the contract
    /// server's temp database. The backend's lazy expiry then lapses it on the next read.
    func expireReservation(_ service: any ClinicService, visitId: String) async throws {
        try SyntheticDatabase(path: database).moveReservationBack(visitId: visitId, minutes: 46)
    }

    // Staff

    private struct Staff {
        let token: String
        let counters: [String]
    }

    private func login(_ staffId: String) async throws -> Staff {
        let answer = try await staff("POST", "/api/staff/login", token: nil, body: ["staff_id": .string(staffId)])
        guard case .string(let token)? = answer["token"], case .array(let counters)? = answer["counters"] else {
            throw ClinicError(status: 0, code: "harness", message: "No staff session for \(staffId)")
        }
        return Staff(token: token, counters: counters.compactMap {
            if case .string(let id)? = $0["id"] { id } else { nil }
        })
    }

    /// The Al Wakra doctor who sits at `counter`.
    private func doctorAt(_ counter: String) async throws -> Staff {
        for doctor in ["S-WAK-DOC1", "S-WAK-DOC2"] {
            let session = try await login(doctor)
            if session.counters.contains(counter) { return session }
        }
        throw ClinicError(status: 0, code: "harness", message: "No doctor sits at \(counter)")
    }

    private func callNext(_ person: Staff, counter: String? = nil, expecting visitId: String) async throws {
        let counter = try #require(counter ?? person.counters.first)
        let answer = try await staff("POST", "/api/counters/\(counter)/call-next", token: person.token)
        #expect(answer["called"]?["visit_id"] == .string(visitId), "call-next at \(counter) called \(answer)")
    }

    private func staff(
        _ method: String, _ path: String, token: String?, body: JSONValue? = nil
    ) async throws -> JSONValue {
        var request = URLRequest(url: try RemoteRequest.url(base: base, path: path))
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw ClinicError(status: response.statusCode, body: data)
        }
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

extension JSONValue {
    fileprivate subscript(key: String) -> JSONValue? {
        if case .object(let fields) = self { fields[key] } else { nil }
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .number(Double(value)) }
    public init(floatLiteral value: Double) { self = .number(value) }
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(elements, uniquingKeysWith: { $1 }))
    }
}

/// The contract server's temp SQLite file. Test-only, synthetic data only.
private struct SyntheticDatabase {
    let path: String

    func moveReservationBack(visitId: String, minutes: Double) throws {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let db = handle else {
            throw failure("open")
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5_000)

        let (id, stamp) = try reserved(db, visitId: visitId)
        let date = try #require(Timestamp.date(from: stamp))
        let moved = Timestamp.string(from: date.addingTimeInterval(-minutes * 60))
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE ticket SET reserved_at = ? WHERE id = ? AND state = 'reserved'",
                                 -1, &statement, nil) == SQLITE_OK else { throw failure("prepare") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, moved, -1, transient)
        sqlite3_bind_text(statement, 2, id, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE, sqlite3_changes(db) == 1 else { throw failure("update") }
    }

    private func reserved(_ db: OpaquePointer, visitId: String) throws -> (String, String) {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, reserved_at FROM ticket WHERE visit_id = ? AND state = 'reserved'",
                                 -1, &statement, nil) == SQLITE_OK else { throw failure("prepare") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, visitId, -1, transient)
        guard sqlite3_step(statement) == SQLITE_ROW,
              let id = sqlite3_column_text(statement, 0), let stamp = sqlite3_column_text(statement, 1)
        else { throw failure("no reserved ticket for \(visitId)") }
        let found = (String(cString: id), String(cString: stamp))
        guard sqlite3_step(statement) == SQLITE_DONE else { throw failure("more than one reserved ticket") }
        return found
    }

    private func failure(_ step: String) -> ClinicError {
        ClinicError(status: 0, code: "harness", message: "SQLite \(step) failed on the contract database")
    }

    private var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }
}
