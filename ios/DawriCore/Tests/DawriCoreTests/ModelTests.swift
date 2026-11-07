import Foundation
import Testing
@testable import DawriCore

private let intakeBase = """
    "emergency": false, "language": "en", "chief_complaint_patient_words": "x",
    "self_medication": [], "service": "gp", "service_confidence": 0.9,
    "questions_asked": 1, "denied_red_flags": []
    """

private func json(_ value: some Encodable) throws -> JSONValue {
    try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
}

@Suite struct ModelTests {
    @Test func `severity_0_10 survives, which convertFromSnakeCase would break`() throws {
        let reply = try Fixture.decode(ChatResponse.self, "chat_intake_done")
        #expect(reply.intake?.severity0To10 == 6)
    }

    @Test func `severity is null when nobody said it`() throws {
        let intake = try decode(Intake.self, json: """
            {\(intakeBase), "severity_0_10": null, "refill_request": null}
            """)
        #expect(intake.severity0To10 == nil)
    }

    @Test func `refill_request as a boolean`() throws {
        let intake = try decode(Intake.self, json: """
            {\(intakeBase), "severity_0_10": 3, "refill_request": true}
            """)
        #expect(intake.refillRequest == .flag(true))
        #expect(try decode(Intake.self, json: String(decoding: JSONEncoder().encode(intake), as: UTF8.self)) == intake)
    }

    @Test func `refill_request as a string, from the real backend`() throws {
        let intake = try #require(try Fixture.decode(Visit.self, "visit_refill_continued").intake)
        #expect(intake.refillRequest == .medicine("amlodipine 5 mg once daily"))
    }

    @Test func `refill_request as null`() throws {
        let intake = try #require(try Fixture.decode(Visit.self, "visit_completed").intake)
        #expect(intake.refillRequest == nil)
    }

    @Test func `refill_request of another type is refused`() {
        #expect(throws: DecodingError.self) {
            try decode(Intake.self, json: """
                {\(intakeBase), "severity_0_10": 3, "refill_request": 7}
                """)
        }
    }

    @Test func `ArriveBody encodes as exactly one form`() throws {
        #expect(try json(ArriveBody.button) == .object(["button": .bool(true)]))
        #expect(try json(ArriveBody.location(lat: 25.5, lng: 51.5))
            == .object(["lat": .number(25.5), "lng": .number(51.5)]))
        #expect(try json(ArriveBody.qrCode("DOOR-C-WAKRA"))
            == .object(["qr_code": .string("DOOR-C-WAKRA")]))
    }

    @Test(arguments: [
        ArriveBody.button, .location(lat: 25.17302, lng: 51.59575), .qrCode("DOOR-C-WAKRA"),
    ])
    func `ArriveBody round-trips`(body: ArriveBody) throws {
        let data = try JSONEncoder().encode(body)
        #expect(try JSONDecoder().decode(ArriveBody.self, from: data) == body)
    }

    @Test(arguments: [
        #"{"button":false}"#, #"{}"#, #"{"lat":1}"#, #"{"button":true,"qr_code":"x"}"#,
        #"{"lat":1,"lng":2,"qr_code":"x"}"#,
    ])
    func `ArriveBody refuses anything but one form`(text: String) {
        #expect(throws: DecodingError.self) { try decode(ArriveBody.self, json: text) }
    }

    @Test func `an unknown AI mode decodes, so the guard can refuse it`() throws {
        let health = try decode(Health.self, json: """
            {"status": "ok", "ai_mode": "turbo", "simulate_load": false}
            """)
        #expect(health.aiMode == .other("turbo"))
        #expect(health.aiMode != .simulated)
        #expect(health.aiMode.rawValue == "turbo")
        let data = try JSONEncoder().encode(health)
        #expect(try JSONDecoder().decode(Health.self, from: data) == health)
    }

    @Test func `real and simulated stay what they are`() throws {
        #expect(try decode(Health.self, json: """
            {"status": "ok", "ai_mode": "real", "simulate_load": false}
            """).aiMode == .real)
        #expect(try Fixture.decode(Health.self, "health").aiMode == .simulated)
    }

    @Test func `Me.record keeps whatever the backend sent`() throws {
        let me = try Fixture.decode(Me.self, "me_with_dependents")
        guard case .object(let bundle) = me.record else {
            Issue.record("record should be an object")
            return
        }
        #expect(bundle["resourceType"] == .string("Bundle"))
        #expect(bundle["demo"] == .bool(true))
    }

    @Test func `Me.record may be null`() throws {
        let me = try Fixture.data("me_no_dependents")
        var fields = try #require(try JSONSerialization.jsonObject(with: me) as? [String: Any])
        fields["record"] = NSNull()
        let data = try JSONSerialization.data(withJSONObject: fields)
        #expect(try JSONDecoder().decode(Me.self, from: data).record == .null)
    }

    @Test func `JSONValue keeps a bool from turning into a number`() throws {
        let value = try decode(JSONValue.self, json: #"{"a": true, "b": 1, "c": [null, "x"]}"#)
        #expect(value == .object([
            "a": .bool(true), "b": .number(1), "c": .array([.null, .string("x")]),
        ]))
    }

    @Test func `TranscribeResponse is a shape only`() throws {
        #expect(try decode(TranscribeResponse.self, json: #"{"text": "x"}"#).text == "x")
    }

    @Test func `flattened types carry their parent's fields`() throws {
        let patient = try Fixture.decode(AuthVerifyResponse.self, "auth_verify").patient
        #expect(patient.qidDemo == "DEMO-10001")
        let list = try Fixture.decode(CentreList.self, "centre_list")
        let first = try #require(list.centres.first)
        #expect(first.nameEn == "Al Wakra Health Centre")
        #expect(first.operator == "PHCC")
        #expect(first.registered)
        let reply = try Fixture.decode(ChatResponse.self, "chat_emergency")
        #expect(reply.nearestEd?.nameEn == "Hamad General Hospital")
    }

    @Test func `the backend's timestamp parses`() throws {
        let date = try #require(Timestamp.date(from: "2026-11-07T09:00:00.500000+00:00"))
        #expect(date.timeIntervalSince1970 == 1_794_042_000.5)
    }

    @Test func `every timestamp in a real visit parses`() throws {
        let visit = try Fixture.decode(Visit.self, "visit_completed")
        #expect(Timestamp.date(from: visit.createdAt) != nil)
        #expect(Timestamp.date(from: try #require(visit.completedAt)) != nil)
        let reserved = try Fixture.decode(ReserveResponse.self, "reserve")
        #expect(Timestamp.date(from: reserved.expiresAt) != nil)
    }

    @Test func `another offset lands on the same moment`() throws {
        let utc = Timestamp.date(from: "2026-11-07T09:00:00.000000+00:00")
        #expect(utc != nil)
        #expect(Timestamp.date(from: "2026-11-07T12:00:00.000000+03:00") == utc)
    }

    @Test(arguments: [
        "", "2026-11-07", "2026-11-07T09:00:00+00:00", "2026-11-07T09:00:00.000Z",
        "2026-13-07T09:00:00.000000+00:00", "2026-02-30T09:00:00.000000+00:00",
    ])
    func `anything else does not parse`(text: String) {
        #expect(Timestamp.date(from: text) == nil)
    }

    @Test func `a timestamp written here reads back in the backend's format`() throws {
        let text = "2026-11-07T09:45:00.901593+00:00"
        let date = try #require(Timestamp.date(from: text))
        #expect(Timestamp.string(from: date) == text)
    }

    @Test func `the live state is plain data`() throws {
        let state = TicketLiveState(
            number: "T-014", stage: .triage, peopleAhead: 3, estWaitMin: 12, counter: "Triage 1")
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(TicketLiveState.self, from: data) == state)
        #expect(Set([state, state]).count == 1)
    }
}
