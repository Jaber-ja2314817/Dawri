import Foundation
import Testing
@testable import DawriCore

/// The alias scrub of `Scrub` in ios/Tools/export/journeys.py, run as a comparison.
///
/// The exporter numbers ids and times by first appearance across a whole walk, staff responses
/// included, and the phone produces no staff responses. So in place of renumbering, each alias
/// the golden holds is paired with the value found in its place. A pair stands for the rest of
/// the walk in both directions, which demands exactly what the numbering does: the same value
/// wherever the golden has the same alias, and a different one wherever it has another.
struct AliasPairs {
    private enum Kind: String {
        case visit = "V"
        case ticket = "T"
        case time = "time"
    }

    private static let real = try! NSRegularExpression(
        pattern: #"V_[0-9a-f]{12}|tkt_[0-9a-f]{12}|\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}\+00:00"#)
    private static let alias = try! NSRegularExpression(pattern: #"^(?:V[0-9]+|T[0-9]+|time[0-9]+)"#)

    private var aliases: [String: String] = [:]
    private var values: [String: String] = [:]

    private static func kind(ofReal value: String) -> Kind {
        value.hasPrefix("V_") ? .visit : value.hasPrefix("tkt_") ? .ticket : .time
    }

    private static func kind(ofAlias alias: String) -> Kind {
        alias.hasPrefix("time") ? .time : alias.hasPrefix("V") ? .visit : .ticket
    }

    /// Records that this alias is this value, or says the two do not fit.
    mutating func pair(alias: String, value: String) -> Bool {
        guard Self.kind(ofAlias: alias) == Self.kind(ofReal: value) else { return false }
        if let known = aliases[alias] { return known == value && values[value] == alias }
        guard values[value] == nil else { return false }
        aliases[alias] = value
        values[value] = alias
        return true
    }

    /// The real id behind an alias in a path. One never seen is the id no visit has, which the
    /// exporter asks for on purpose.
    func resolve(_ alias: String) -> String {
        aliases[alias] ?? "V_000000000000"
    }

    private mutating func sameText(_ expected: String, _ found: String) -> Bool {
        let whole = found as NSString
        let range = NSRange(location: 0, length: whole.length)
        var rest = expected as NSString
        var cursor = 0
        for match in Self.real.matches(in: found, range: range) {
            let literal = whole.substring(
                with: NSRange(location: cursor, length: match.range.location - cursor))
            guard rest.length >= (literal as NSString).length,
                  sameScalars(rest.substring(to: (literal as NSString).length), literal)
            else { return false }
            rest = rest.substring(from: (literal as NSString).length) as NSString
            let head = Self.alias.firstMatch(
                in: rest as String, range: NSRange(location: 0, length: rest.length))
            guard let head else { return false }
            guard pair(alias: rest.substring(with: head.range), value: whole.substring(with: match.range))
            else { return false }
            rest = rest.substring(from: head.range.length) as NSString
            cursor = match.range.location + match.range.length
        }
        return sameScalars(rest as String, whole.substring(from: cursor))
    }

    mutating func same(_ expected: JSONValue, _ found: JSONValue) -> Bool {
        switch (expected, found) {
        case (.string(let want), .string(let got)):
            return sameText(want, got)
        case (.array(let want), .array(let got)):
            guard want.count == got.count else { return false }
            for (first, second) in zip(want, got) where !same(first, second) { return false }
            return true
        case (.object(let want), .object(let got)):
            guard want.count == got.count else { return false }
            for key in want.keys.sorted() {
                guard let first = want[key], let second = got[key], same(first, second) else {
                    return false
                }
            }
            return true
        default:
            return sameJSON(expected, found)
        }
    }
}

/// One clinic replaying one recorded walk: the patient's requests through the service, and what
/// the staff consoles and the harness did through the engine, as the phone has no staff routes.
final class ApiReplayer {
    let clock: TestClock
    let service: LocalClinicService
    var pairs = AliasPairs()
    private var sessions: [String: SessionSubject] = [
        "nurse": SessionSubject(kind: .staff, id: "S-WAK-NURSE1"),
        "doctor": SessionSubject(kind: .staff, id: "S-WAK-DOC2"),
        "pharmacist": SessionSubject(kind: .staff, id: "S-WAK-PHARM1"),
    ]
    private var created = 0

    init() throws {
        clock = try TestClock(journeyStart)
        let clock = clock
        service = LocalClinicService(
            clock: { clock.now }, store: MemoryClinicStore(), demoClinic: false)
    }

    /// `expected` is the recorded body, and `found` the phone's own, each through its model.
    struct Answer {
        var expected: JSONValue?
        var found: JSONValue?
        var refused: ClinicError?
    }

    private func model<T: Codable>(_ type: T.Type, _ value: JSONValue?) throws -> JSONValue? {
        guard let value else { return nil }
        let decoded = try JSONDecoder().decode(type, from: JSONEncoder().encode(value))
        return try plainJSON(decoded)
    }

    private func path(_ text: String) -> (route: [String], query: [String: String]) {
        let parts = text.split(separator: "?", maxSplits: 1).map(String.init)
        var query: [String: String] = [:]
        if parts.count > 1 {
            for pair in parts[1].split(separator: "&") {
                let field = pair.split(separator: "=", maxSplits: 1).map(String.init)
                query[field[0]] = field.count > 1 ? field[1] : ""
            }
        }
        return (parts[0].split(separator: "/").map(String.init), query)
    }

    /// Runs one row. Patient routes answer through the service, staff routes through `staff`.
    func run(actor: String, method: String, rawPath: String, request: JSONValue?, response: JSONValue?) async throws
        -> Answer
    {
        switch actor {
        case "harness":
            try await harness(sql: rawPath, request: request)
            return Answer()
        case "clock":
            clock.advance(seconds: Double((request?.object?["minutes"]?.int ?? 0) * 60))
            return Answer()
        default:
            break
        }
        clock.advance(seconds: 1)
        await service.adoptSession(sessions[actor])
        do {
            if ["nurse", "doctor", "pharmacist"].contains(actor) && !rawPath.hasSuffix("/api/me") {
                return try await staff(rawPath: rawPath, request: request, response: response)
            }
            return try await patient(actor: actor, method: method, rawPath: rawPath, request: request, response: response)
        } catch let error as ClinicError {
            return Answer(refused: error)
        }
    }

    private func patient(
        actor: String, method: String, rawPath: String, request: JSONValue?, response: JSONValue?
    ) async throws -> Answer {
        let (route, query) = path(rawPath)
        let body = request?.object ?? [:]
        let tail = Array(route.dropFirst(1))  // Past "api".

        func answer<T: Codable>(_ found: T, _ expected: JSONValue? = nil) throws -> Answer {
            try compared(found, expected ?? response)
        }

        switch (method, tail.first, tail.count) {
        case ("GET", "auth", 2):
            return try answer(await service.demoPatients())
        case ("GET", "health", 1):
            return try answer(await service.health())
        case ("POST", "auth", 2) where tail[1] == "start":
            return try answer(try await service.authStart(qid: body["qid"]?.string ?? ""))
        case ("POST", "auth", 2):
            let patient = try await service.routeVerify(
                qid: body["qid"]?.string ?? "", otp: body["otp"]?.string)
            sessions[actor] = SessionSubject(kind: .patient, id: patient.id)
            return try answer(patient, response?.object?["patient"])
        case ("GET", "me", 1):
            return try answer(try await service.getMe())
        case ("GET", "visits", 1):
            return try answer(try await service.listVisits())
        case ("POST", "visits", 1):
            let made = try await service.routeCreateVisit(
                consent: body["consent"] == .bool(true), patientId: body["patient_id"]?.string)
            created += 1
            guard pairs.pair(alias: "V\(created)", value: made.visitId) else {
                Issue.record("V\(created) is already another visit")
                return Answer()
            }
            return try answer(made)
        case ("GET", "centres", 1):
            return try answer(
                try await service.routeCentres(
                    service: query["service"] ?? "gp", visitId: query["visit_id"].map(pairs.resolve),
                    lat: query["lat"].flatMap(Double.init), lng: query["lng"].flatMap(Double.init)))
        case ("GET", "visits", 2):
            return try answer(try await service.getVisit(visitId: pairs.resolve(tail[1])))
        case ("POST", "visits", 3):
            return try await visitAction(
                visitId: pairs.resolve(tail[1]), action: tail[2], body: body, response: response)
        case ("POST", "visits", 4) where tail[2] == "intake":
            let wanted = body["json"]?.object?["service"]?.string
            return try answer(
                try await service.routeConfirm(visitId: pairs.resolve(tail[1]), service: wanted))
        case ("POST", "visits", 4) where tail[2] == "refill":
            return try answer(try await service.continueRefill(visitId: pairs.resolve(tail[1])))
        case ("POST", "visits", 4) where tail[2] == "emergency":
            return try answer(try await service.emergencyOverride(visitId: pairs.resolve(tail[1])))
        default:
            Issue.record("No patient route for \(method) \(rawPath)")
            return Answer()
        }
    }

    private func compared<T: Codable>(_ found: T, _ expected: JSONValue?) throws -> Answer {
        Answer(expected: try model(T.self, expected), found: try plainJSON(found))
    }

    private func visitAction(
        visitId: String, action: String, body: [String: JSONValue], response: JSONValue?
    ) async throws -> Answer {
        switch action {
        case "chat":
            return try compared(
                try await service.routeChat(visitId: visitId, text: body["text"]?.string), response)
        case "reserve":
            return try compared(
                try await service.routeReserve(visitId: visitId, centreId: body["centre_id"]?.string),
                response)
        case "arrive":
            let request = LocalClinicService.ArrivalRequest(
                lat: body["lat"]?.double, lng: body["lng"]?.double, qrCode: body["qr_code"]?.string,
                button: body["button"] == .bool(true) ? true : nil)
            return try compared(
                try await service.routeArrive(visitId: visitId, body: request), response)
        case "rating":
            return try compared(
                try await service.routeRate(visitId: visitId, stars: body["stars"]?.int), response)
        default:
            Issue.record("No patient action \(action)")
            return Answer()
        }
    }

    private func harness(sql: String, request: JSONValue?) async throws {
        let params = request?.object?["params"]?.array?.compactMap(\.string) ?? []
        if sql.hasPrefix("UPDATE drug") {
            let drug = try #require(params.first)
            await service.testing { state, _ in
                let index = state.clinic.drugs.firstIndex { $0.id == drug }
                if let index { state.clinic.drugs[index].demoDefault = 1 }
            }
        } else if sql.hasPrefix("UPDATE visit") {
            let visitId = pairs.resolve(try #require(params.first))
            await service.testing { state, _ in
                state.clinic.updateVisit(visitId) {
                    $0.status = .redirectedEmergency
                    $0.patientId = "P001"
                }
            }
        } else {
            Issue.record("No harness step for \(sql)")
        }
    }

    /// The staff routes of backend/routers/staff.py and demo.py, by the same engine calls.
    private func staff(rawPath: String, request: JSONValue?, response: JSONValue?) async throws -> Answer {
        let route = path(rawPath).route
        let action = route.suffix(2).joined(separator: "/")
        let visitId = route[1] == "visits" ? pairs.resolve(route[2]) : pairs.resolve(route[route.count - 1])

        if route[1] == "counters" {
            let counterId = route[2]
            let (called, finished) = try await service.testing { state, engine in
                let result = try engine.callNext(&state.clinic, counterId: counterId)
                let shown = try result.called.map { try engine.ticketView(&state.clinic, ticket: $0) }
                return (shown, result.autoCompleted.compactMap(\.number))
            }
            return Answer(
                expected: .object([
                    "called": response?.object?["called"] ?? .null,
                    "auto_completed": response?.object?["auto_completed"] ?? .array([]),
                ]),
                found: .object([
                    "called": try called.map { try plainJSON($0) } ?? .null,
                    "auto_completed": .array(finished.map(JSONValue.string)),
                ]))
        }

        switch action {
        case let tail where tail.hasSuffix("/vitals"):
            let shown = try await service.testing { state, engine in
                var ticket = try #require(engine.liveTicket(state.clinic, visitId: visitId))
                if ticket.state == .called { ticket = try engine.serve(&state.clinic, ticketId: ticket.id) }
                return try engine.ticketView(&state.clinic, ticket: ticket)
            }
            return try ticket(shown, response)

        case "handoff/draft":
            let ids = await service.testing { state, _ in
                guard let visit = state.clinic.visit(visitId), let centre = visit.centreId,
                      let patient = state.clinic.patient(visit.patientId)
                else { return [String]() }
                return DoctorRules.suggest(
                    state.clinic, centreId: centre, service: visit.service?.rawValue ?? "other",
                    patientLang: patient.preferredLang
                ).map(\.doctorId)
            }
            let expected = response?.object?["suggestions"]?.array?.compactMap { $0.object?["doctor_id"]?.string }
            return Answer(
                expected: .array((expected ?? []).map(JSONValue.string)),
                found: .array(ids.map(JSONValue.string)))

        case "handoff/confirm":
            let doctor = try #require(request?.object?["doctor_id"]?.string)
            let shown = try await service.testing { state, engine in
                let ticket = try #require(engine.liveTicket(state.clinic, visitId: visitId))
                let counter = try #require(state.clinic.counters.first { $0.staffId == doctor })
                let moved = try engine.advance(
                    &state.clinic, ticketId: ticket.id, nextCounterId: counter.id)
                return try engine.ticketView(&state.clinic, ticket: moved)
            }
            return try self.ticket(shown, response)

        case "consult/done":
            let drugs = request?.object?["prescription"]?.array?.compactMap { $0.object?["drug_id"]?.string } ?? []
            let shown = try await service.testing { state, engine in
                let ticket = try #require(engine.liveTicket(state.clinic, visitId: visitId))
                let items = try VisitFlow.resolveItems(
                    state.clinic, items: drugs.map { PrescriptionRequest(drugId: $0) })
                let moved = try VisitFlow.completeConsult(
                    &engine, &state.clinic, visitId: visitId, ticket: ticket, items: items,
                    actor: "S-WAK-DOC2")
                return try engine.ticketView(&state.clinic, ticket: moved)
            }
            return try self.ticket(shown, response)

        case let tail where tail.hasSuffix("/dispensed"):
            try await service.testing { state, engine in
                let ticket = try #require(engine.liveTicket(state.clinic, visitId: visitId))
                _ = try VisitFlow.dispense(
                    &engine, &state.clinic, visitId: visitId, ticket: ticket, actor: "S-WAK-PHARM1")
            }
            return try await medicines(visitId: visitId, response)

        case let tail where tail.hasPrefix("fast-forward"):
            try await fastForward(visitId: visitId)
            return try await medicines(visitId: visitId, response)

        default:
            Issue.record("No staff route for \(rawPath)")
            return Answer()
        }
    }

    private func ticket(_ shown: Ticket, _ response: JSONValue?) throws -> Answer {
        Answer(expected: try model(Ticket.self, response?.object?["ticket"]), found: try plainJSON(shown))
    }

    private func medicines(visitId: String, _ response: JSONValue?) async throws -> Answer {
        let lines = await service.testing { state, _ in
            VisitMedicines(
                en: MedicineLines.forVisit(state.clinic, visitId: visitId, lang: "en"),
                ar: MedicineLines.forVisit(state.clinic, visitId: visitId, lang: "ar"))
        }
        return Answer(
            expected: try model(VisitMedicines.self, response?.object?["medicines"]),
            found: try plainJSON(lines))
    }

    /// `fast_forward`, walking doctor and pharmacy through the engine.
    private func fastForward(visitId: String) async throws {
        try await service.testing { state, engine in
            func toCounter(_ ticket: TicketRecord) throws -> TicketRecord {
                if ticket.state == .called || ticket.state == .serving { return ticket }
                return try #require(
                    try engine.callNext(&state.clinic, counterId: ticket.counterId).called)
            }
            let visit = try #require(state.clinic.visit(visitId))
            let patient = try #require(state.clinic.patient(visit.patientId))
            let items = try VisitFlow.defaultItems(state.clinic, allergies: patient.allergies)
            var ticket = try toCounter(try #require(engine.liveTicket(state.clinic, visitId: visitId)))
            ticket = try VisitFlow.completeConsult(
                &engine, &state.clinic, visitId: visitId, ticket: ticket, items: items, actor: "demo:S")
            if ticket.state != .done {
                ticket = try toCounter(ticket)
                _ = try VisitFlow.dispense(
                    &engine, &state.clinic, visitId: visitId, ticket: ticket, actor: "demo:S")
            }
        }
    }
}
