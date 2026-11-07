import Foundation
import Testing
@testable import DawriCore

private struct FixtureCase: Sendable, CustomTestStringConvertible {
    let name: String
    let check: @Sendable (Data) throws -> Void
    var testDescription: String { name }

    init<T: Codable & Equatable & SendableMetatype>(_ name: String, _ type: T.Type) {
        self.name = name
        self.check = { data in
            let value = try JSONDecoder().decode(T.self, from: data)
            let encoded = try JSONEncoder().encode(value)
            #expect(try JSONDecoder().decode(T.self, from: encoded) == value)

            // Nothing the backend sent was dropped or renamed on the way through.
            let sent = try JSONDecoder().decode(JSONValue.self, from: data)
            let kept = try JSONDecoder().decode(JSONValue.self, from: encoded)
            #expect(withoutNulls(sent) == withoutNulls(kept))
        }
    }
}

private let cases: [FixtureCase] = [
    FixtureCase("health", Health.self),
    FixtureCase("demo_patients", [DemoPatient].self),
    FixtureCase("auth_start", AuthStartResponse.self),
    FixtureCase("auth_verify", AuthVerifyResponse.self),
    FixtureCase("me_with_dependents", Me.self),
    FixtureCase("me_no_dependents", Me.self),
    FixtureCase("create_visit", CreateVisitResponse.self),
    FixtureCase("chat_turn", ChatResponse.self),
    FixtureCase("chat_intake_done", ChatResponse.self),
    FixtureCase("chat_emergency", ChatResponse.self),
    FixtureCase("chat_refill", ChatResponse.self),
    FixtureCase("confirm", ConfirmResponse.self),
    FixtureCase("confirm_refill_continue", ConfirmResponse.self),
    FixtureCase("override", OverrideResponse.self),
    FixtureCase("centre_list", CentreList.self),
    FixtureCase("centre_list_fallback", CentreList.self),
    FixtureCase("centre_list_suggestion", CentreList.self),
    FixtureCase("reserve", ReserveResponse.self),
    FixtureCase("arrive", ArriveResponse.self),
    FixtureCase("rating", RatingResponse.self),
    FixtureCase("visit_rows", [VisitRow].self),
    FixtureCase("visit_intake", Visit.self),
    FixtureCase("visit_intake_done", Visit.self),
    FixtureCase("visit_intake_confirmed", Visit.self),
    FixtureCase("visit_emergency", Visit.self),
    FixtureCase("visit_refill", Visit.self),
    FixtureCase("visit_refill_continued", Visit.self),
    FixtureCase("visit_reserved", Visit.self),
    FixtureCase("visit_expired", Visit.self),
    FixtureCase("visit_triage", Visit.self),
    FixtureCase("visit_triage_called", Visit.self),
    FixtureCase("visit_doctor", Visit.self),
    FixtureCase("visit_pharmacy", Visit.self),
    FixtureCase("visit_completed", Visit.self),
    FixtureCase("visit_completed_rated", Visit.self),
    FixtureCase("visit_dependent", Visit.self),
    FixtureCase("visit_cancelled", Visit.self),
]

/// Read as ClinicError by ServiceTests, not as a model.
private let errorBodies: Set<String> = ["api_error", "api_error_ar"]

@Suite("Fixtures from the real backend")
struct FixtureTests {
    @Test("decodes and round-trips", arguments: cases)
    fileprivate func roundTrip(_ fixture: FixtureCase) throws {
        try fixture.check(try Fixture.data(fixture.name))
    }

    @Test func `every file in the folder is tested`() throws {
        let files = try FileManager.default.contentsOfDirectory(
            at: try Fixture.folder, includingPropertiesForKeys: nil)
        let found = Set(files.filter { $0.pathExtension == "json" }
            .map { $0.deletingPathExtension().lastPathComponent })
        #expect(found == Set(cases.map(\.name)).union(errorBodies))
    }

    @Test func `the backend's stage names reach every stage`() throws {
        let stages = try cases.filter { $0.name.hasPrefix("visit_") && $0.name != "visit_rows" }
            .map { try Fixture.decode(Visit.self, $0.name).stage }
        #expect(Set(stages) == Set(VisitStage.allCases))
    }

    @Test func `status and stage agree in every visit`() throws {
        for fixture in cases where fixture.name.hasPrefix("visit_") && fixture.name != "visit_rows" {
            let visit = try Fixture.decode(Visit.self, fixture.name)
            #expect(visit.status.stage == visit.stage, "\(fixture.name)")
        }
    }

    @Test func `a reserved ticket has no number and no place`() throws {
        let ticket = try #require(try Fixture.decode(Visit.self, "visit_reserved").ticket)
        #expect(ticket.state == .reserved)
        #expect(ticket.number == nil)
        #expect(ticket.peopleAhead == nil)
        #expect(ticket.estWaitMin == nil)
        #expect(ticket.expiresAt != nil)
    }

    @Test func `the override gives no ticket`() throws {
        let override = try Fixture.decode(OverrideResponse.self, "override")
        #expect(override.ticket == nil)
        #expect(override.status == .redirectedEmergency)
    }

    @Test func `fixtures hold no real token`() throws {
        let login = try Fixture.decode(AuthVerifyResponse.self, "auth_verify")
        #expect(login.token == "fixture-token-not-real")
    }

    @Test func `a Fatima visit keeps her allergy and the Arabic chat`() throws {
        let login = try Fixture.decode(AuthVerifyResponse.self, "auth_verify")
        #expect(login.patient.allergies == ["penicillin"])
        #expect(login.patient.registeredCentre.id == "C-WAKRA")
        let visit = try Fixture.decode(Visit.self, "visit_completed")
        #expect(visit.chat.language == "ar")
        #expect(visit.medicines.en.count == 2)
        #expect(visit.ticket?.number == "P-031")
    }
}
