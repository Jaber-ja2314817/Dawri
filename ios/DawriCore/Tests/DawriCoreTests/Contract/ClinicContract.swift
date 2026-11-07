import Foundation
import Testing
@testable import DawriCore

private let fatimaQid = "DEMO-10001"
private let ahmedQid = "DEMO-10002"
private let raviQid = "DEMO-10003"

private let symptoms = [
    "ar": ["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"],
    "en": ["I have a fever and cough for three days", "6", "panadol", "no"],
]
private let refillAsk = ["ar": "أبي حبوب الضغط المعتادة", "en": "I need my usual blood pressure tablets."]
private let redFlag = ["ar": "عندي ألم في الصدر ينتشر إلى ذراعي", "en": "Chest pain going to my left arm."]
private let languages = ["ar", "en"]

/// The refusal a call ends in, or nil if it went through.
private func refusal<Value>(_ call: () async throws -> Value) async throws -> ClinicError? {
    do {
        _ = try await call()
        return nil
    } catch let error as ClinicError {
        return error
    }
}

private func expectRefused<Value>(
    _ status: Int, _ code: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ call: () async throws -> Value
) async throws {
    let error = try await refusal(call)
    #expect(error?.status == status, sourceLocation: sourceLocation)
    #expect(error?.code == code, sourceLocation: sourceLocation)
}

private func signedIn(_ service: any ClinicService, _ qid: String) async throws {
    _ = try await service.authStart(qid: qid)
    _ = try await service.authVerify(qid: qid, otp: "0000")
}

/// A chat finished in `language`, with the read-back waiting.
private func chatted(_ service: any ClinicService, language: String = "en", patient: String? = nil)
    async throws -> String
{
    let visit = try await service.createVisit(patientId: patient).visitId
    for line in try #require(symptoms[language]) {
        _ = try await service.sendChat(visitId: visit, text: line)
    }
    return visit
}

private func confirmed(_ service: any ClinicService, language: String = "en", patient: String? = nil)
    async throws -> String
{
    let visit = try await chatted(service, language: language, patient: patient)
    _ = try await service.confirmIntake(visitId: visit, service: nil)
    return visit
}

private func reserved(_ service: any ClinicService, centre: String = "C-WAKRA") async throws -> String {
    let visit = try await confirmed(service)
    _ = try await service.reserve(visitId: visit, centreId: centre)
    return visit
}

/// What every back end must do the same way. It speaks only through `ClinicService` and
/// `ContractHarness`, so it names no concrete service.
@Suite("Clinic contract")
struct ClinicContract {
    // Signing in

    @Test(arguments: contractHarnesses)
    func `signing in keeps the session`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        #expect(await !service.isSignedIn)
        #expect(try await service.authStart(qid: fatimaQid).otpSent)
        #expect(await !service.isSignedIn)
        let patient = try await service.authVerify(qid: fatimaQid, otp: "0000")
        #expect(patient.id == "P001")
        #expect(patient.allergies == ["penicillin"])
        #expect(patient.demo)
        #expect(await service.isSignedIn)
    }

    @Test(arguments: contractHarnesses)
    func `each way signing in fails`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await expectRefused(404, "unknown_qid") { try await service.authStart(qid: "DEMO-99999") }
        try await expectRefused(404, "unknown_qid") {
            try await service.authVerify(qid: "DEMO-99999", otp: "0000")
        }
        try await expectRefused(401, "invalid_otp") {
            try await service.authVerify(qid: fatimaQid, otp: "1234")
        }
        try await expectRefused(401, "invalid_otp") {
            try await service.authVerify(qid: fatimaQid, otp: "")
        }
        #expect(await !service.isSignedIn)
        try await expectRefused(401, "unauthorized") { try await service.getMe() }
        try await expectRefused(401, "unauthorized") { try await service.listVisits() }
        try await expectRefused(401, "unauthorized") { try await service.createVisit(patientId: nil) }
    }

    @Test(arguments: contractHarnesses)
    func `the demo patients need no session`(harness: any ContractHarness) async throws {
        let patients = try await harness.makeService().demoPatients()
        #expect(Array(patients.map(\.id).prefix(3)) == ["P001", "P002", "P003"])
        #expect(Array(patients.map(\.qidDemo).prefix(3)) == [fatimaQid, ahmedQid, raviQid])
        #expect(!patients.contains { $0.id == "P004" }, "A dependent signs in through a guardian")
        #expect(patients.allSatisfy { !$0.fullNameEn.isEmpty && !$0.fullNameAr.isEmpty })
    }

    @Test(arguments: contractHarnesses)
    func `health says simulated`(harness: any ContractHarness) async throws {
        let health = try await harness.makeService().health()
        #expect(health.status == "ok")
        #expect(health.aiMode == .simulated)
    }

    @Test(arguments: contractHarnesses)
    func `me with dependents`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let me = try await service.getMe()
        #expect(me.patient.id == "P001")
        #expect(me.dependents.map(\.id) == ["P004", "P005"])
        guard case .object(let record) = me.record else {
            Issue.record("The record is not an object")
            return
        }
        #expect(record["resourceType"] == .string("Bundle"))
        #expect(record["demo"] == .bool(true))
    }

    @Test(arguments: contractHarnesses)
    func `me without dependents`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, ahmedQid)
        let me = try await service.getMe()
        #expect(me.patient.id == "P002")
        #expect(me.dependents.isEmpty)
        #expect(!me.patient.activeMeds.isEmpty)
    }

    // Starting a visit

    @Test(arguments: contractHarnesses)
    func `a new visit opens at intake with the opening line`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let created = try await service.createVisit(patientId: nil)
        #expect(created.status == .intake)
        #expect(created.language == "ar")
        #expect(!created.opening.isEmpty)
        let visit = try await service.getVisit(visitId: created.visitId)
        #expect(visit.stage == .intake)
        #expect(visit.ticket == nil)
        #expect(visit.intake == nil)
        #expect(!visit.confirmedByPatient)
        #expect(visit.chat.messages.map(\.content) == [created.opening])
        #expect(visit.chat.messages.first?.slot == "complaint")
    }

    /// The protocol always sends consent, so what is left to pin is who it covers.
    @Test(arguments: contractHarnesses)
    func `the consent body names who the visit is for`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let own = try await service.createVisit(patientId: nil)
        let ownVisit = try await service.getVisit(visitId: own.visitId)
        #expect(ownVisit.patientId == "P001")
        #expect(ownVisit.bookedBy == "P001")
        let dependent = try await service.createVisit(patientId: "P004")
        let dependentVisit = try await service.getVisit(visitId: dependent.visitId)
        #expect(dependentVisit.patientId == "P004")
        #expect(dependentVisit.bookedBy == "P001")
        try await expectRefused(403, "forbidden") { try await service.createVisit(patientId: "P003") }
    }

    @Test(arguments: contractHarnesses)
    func `a visit is only for those it belongs to`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(404, "visit_not_found") {
            try await service.getVisit(visitId: "V_000000000000")
        }
        try await signedIn(service, raviQid)
        try await expectRefused(403, "forbidden") { try await service.getVisit(visitId: visit) }
        try await expectRefused(403, "forbidden") {
            try await service.sendChat(visitId: visit, text: "hi")
        }
    }

    // The chat

    @Test(arguments: contractHarnesses, languages)
    func `the chat reaches a finished intake`(harness: any ContractHarness, language: String) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        let lines = try #require(symptoms[language])
        var last: ChatResponse?
        for (index, line) in lines.enumerated() {
            let reply = try await service.sendChat(visitId: visit, text: line)
            #expect(reply.status == .intake)
            #expect(reply.aiSource == "simulated")
            #expect(reply.transcript == nil)
            #expect(reply.done == (index == lines.count - 1))
            last = reply
        }
        let intake = try #require(last?.intake)
        #expect(intake.service == .gp)
        #expect(intake.selfMedication == ["paracetamol"])
        #expect(intake.severity0To10 == 6)
        #expect(intake.language.hasPrefix(language))
        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.intake == intake)
        #expect(stored.service == .gp)
        #expect(!stored.confirmedByPatient)
        #expect(stored.chat.messages.count == 1 + 2 * lines.count)
    }

    @Test(arguments: contractHarnesses)
    func `an empty or over long message is refused`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(422, "invalid_text") {
            try await service.sendChat(visitId: visit, text: "  \n ")
        }
        try await expectRefused(422, "invalid_text") {
            try await service.sendChat(visitId: visit, text: String(repeating: "a ", count: 1001))
        }
    }

    @Test(arguments: contractHarnesses)
    func `confirming the read back`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let empty = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(409, "no_intake") {
            try await service.confirmIntake(visitId: empty, service: nil)
        }
        for line in try #require(symptoms["en"]) {
            _ = try await service.sendChat(visitId: empty, text: line)
        }
        let answer = try await service.confirmIntake(visitId: empty, service: .dental)
        #expect(answer.status == .intake)
        #expect(answer.service == .dental)
        #expect(answer.intake != nil)
        let visit = try await service.getVisit(visitId: empty)
        #expect(visit.confirmedByPatient)
        #expect(visit.service == .dental)
    }

    // Centres

    @Test(arguments: contractHarnesses)
    func `the centre list leads with the patient's own centre`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await confirmed(service)
        let list = try await service.listCentres(service: "gp", visitId: visit, lat: nil, lng: nil)
        #expect(list.service == "gp")
        #expect(list.effectiveService == "gp")
        #expect(!list.serviceFallback)
        #expect(list.defaultCentreId == "C-WAKRA")
        #expect(list.centres.first?.id == "C-WAKRA")
        #expect(list.centres.first?.registered == true)
        #expect(list.centres.allSatisfy { $0.waitMin != nil && $0.distanceKm == nil })
        #expect(!list.centres.contains { $0.id.hasPrefix("H-") }, "Hospitals are for emergencies")

        let located = try await service.listCentres(service: "gp", visitId: visit, lat: 25.2, lng: 51.5)
        #expect(located.centres.allSatisfy { $0.distanceKm != nil })
    }

    @Test(arguments: contractHarnesses)
    func `the other centre lists`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await confirmed(service)
        let routed = try await service.listCentres(
            service: "mental_health", visitId: visit, lat: nil, lng: nil)
        #expect(routed.effectiveService == "gp")
        #expect(routed.serviceFallback)
        let emergency = try await service.listCentres(
            service: "emergency", visitId: visit, lat: nil, lng: nil)
        #expect(emergency.effectiveService == "emergency")
        #expect(!emergency.centres.isEmpty)
        #expect(emergency.centres.allSatisfy { $0.waitMin == nil && $0.distanceKm != nil })
        #expect(emergency.suggestion == nil)
        try await expectRefused(422, "unknown_service") {
            try await service.listCentres(service: "nope", visitId: visit, lat: nil, lng: nil)
        }
    }

    // Reserving

    @Test(arguments: contractHarnesses)
    func `a reservation has no number and no place`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await confirmed(service)
        let reserved = try await service.reserve(visitId: visit, centreId: "C-WAKRA")
        #expect(reserved.ticket.state == .reserved)
        #expect(reserved.ticket.number == nil)
        #expect(reserved.ticket.peopleAhead == nil)
        #expect(reserved.ticket.estWaitMin == nil)
        #expect(reserved.checkInValidMin == 45)
        #expect(reserved.message == "Check-in valid for 45 minutes")
        #expect(!reserved.messageAr.isEmpty)
        #expect(reserved.ticket.expiresAt == reserved.expiresAt)
        let created = try await service.getVisit(visitId: visit).createdAt
        let minutes = try #require(Timestamp.date(from: reserved.expiresAt))
            .timeIntervalSince(try #require(Timestamp.date(from: created))) / 60
        #expect(minutes > 44 && minutes <= 46)

        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.stage == .reserved)
        #expect(stored.centre?.id == "C-WAKRA")
        #expect(stored.ticket?.number == nil)
        #expect(stored.goTo == nil)
    }

    @Test(arguments: contractHarnesses)
    func `each way reserving is refused`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let open = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(404, "unknown_centre") {
            try await service.reserve(visitId: open, centreId: "C-NOPE")
        }
        try await expectRefused(409, "intake_not_confirmed") {
            try await service.reserve(visitId: open, centreId: "C-WAKRA")
        }
        for line in try #require(symptoms["en"]) {
            _ = try await service.sendChat(visitId: open, text: line)
        }
        _ = try await service.confirmIntake(visitId: open, service: .dental)
        try await expectRefused(409, "service_not_offered") {
            try await service.reserve(visitId: open, centreId: "C-RAYYAN")
        }
        try await expectRefused(409, "service_not_offered") {
            try await service.reserve(visitId: open, centreId: "H-HGH")
        }
    }

    @Test(arguments: contractHarnesses)
    func `a lapsed reservation can be taken again`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        try await harness.expireReservation(service, visitId: visit)
        let lapsed = try await service.getVisit(visitId: visit)
        #expect(lapsed.stage == .expired)
        #expect(lapsed.ticket == nil)
        try await expectRefused(410, "ticket_expired") {
            try await service.arrive(visitId: visit, body: .button)
        }
        let again = try await service.reserve(visitId: visit, centreId: "C-WAKRA")
        #expect(again.ticket.state == .reserved)
    }

    // Arriving

    @Test(arguments: contractHarnesses)
    func `arriving by the button gives the number`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        let arrived = try await service.arrive(visitId: visit, body: .button)
        #expect(arrived.ticket.number == "T-014")
        #expect(arrived.ticket.state == .active)
        #expect(arrived.ticket.peopleAhead == 3)
        #expect(arrived.ticket.estWaitMin != nil)
        #expect(arrived.ticket.expiresAt == nil)
        #expect(arrived.goTo?.counter == arrived.ticket.counter)
        #expect(try await service.getVisit(visitId: visit).stage == .triage)
    }

    @Test(arguments: contractHarnesses)
    func `arriving by the door code`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        try await expectRefused(409, "wrong_door") {
            try await service.arrive(visitId: visit, body: .qrCode("DOOR-C-RAYYAN"))
        }
        #expect(try await service.getVisit(visitId: visit).stage == .reserved)
        let arrived = try await service.arrive(visitId: visit, body: .qrCode("DOOR-C-WAKRA"))
        #expect(arrived.ticket.number == "T-014")
    }

    @Test(arguments: contractHarnesses)
    func `arriving by location`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        let far = try await refusal {
            try await service.arrive(visitId: visit, body: .location(lat: 25.2, lng: 51.5))
        }
        #expect(far?.status == 409)
        #expect(far?.code == "too_far")
        #expect(far?.extra["distance_m"] != nil)
        let arrived = try await service.arrive(
            visitId: visit, body: .location(lat: 25.17302, lng: 51.59575))
        #expect(arrived.ticket.number == "T-014")
    }

    @Test(arguments: contractHarnesses)
    func `arriving needs a reservation and only works once`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let open = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(409, "no_reservation") {
            try await service.arrive(visitId: open, body: .button)
        }
        let held = try await confirmed(service, patient: "P005")
        _ = try await service.reserve(visitId: held, centreId: "C-WAKRA")
        _ = try await service.arrive(visitId: held, body: .button)
        try await expectRefused(409, "invalid_transition") {
            try await service.arrive(visitId: held, body: .button)
        }
    }

    // The visit

    @Test(arguments: contractHarnesses)
    func `the stages walk to completed`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        _ = try await service.arrive(visitId: visit, body: .button)
        var numbers: [String?] = []
        var stages: [VisitStage] = []
        for _ in 0..<3 {
            try await harness.moveToNextStage(service, visitId: visit)
            let moved = try await service.getVisit(visitId: visit)
            stages.append(moved.stage)
            numbers.append(moved.ticket?.number)
        }
        #expect(stages == [.doctor, .pharmacy, .completed])
        #expect(numbers.prefix(2) == ["D-GP-023", "P-031"])

        let done = try await service.getVisit(visitId: visit)
        #expect(done.completedAt != nil)
        #expect(done.ticket?.state == .done)
        #expect(done.goTo == nil)
        let drugs = done.medicines.en.map(\.name).joined(separator: " ").lowercased()
        #expect(drugs.contains("paracetamol"))
        #expect(drugs.contains("dextromethorphan"))
        #expect(!drugs.contains("cillin"))
        #expect(done.medicines.ar.count == done.medicines.en.count)
    }

    @Test(arguments: contractHarnesses)
    func `a visit is rated once`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        try await expectRefused(409, "visit_not_completed") {
            try await service.rateVisit(visitId: visit, stars: 5)
        }
        _ = try await service.arrive(visitId: visit, body: .button)
        for _ in 0..<3 { try await harness.moveToNextStage(service, visitId: visit) }
        try await expectRefused(422, "invalid_request") {
            try await service.rateVisit(visitId: visit, stars: 6)
        }
        #expect(try await service.rateVisit(visitId: visit, stars: 4).rating == 4)
        #expect(try await service.getVisit(visitId: visit).rating == 4)
        try await expectRefused(409, "already_rated") {
            try await service.rateVisit(visitId: visit, stars: 5)
        }
        #expect(try await service.getVisit(visitId: visit).rating == 4)
    }

    @Test(arguments: contractHarnesses)
    func `history is newest first with dependents`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        #expect(try await service.listVisits().isEmpty)
        let first = try await reserved(service)
        let second = try await service.createVisit(patientId: "P004").visitId
        let rows = try await service.listVisits()
        #expect(rows.map(\.visitId) == [second, first])
        #expect(rows.map(\.patientId) == ["P004", "P001"])
        #expect(rows.map(\.stage) == [.intake, .reserved])
        #expect(rows.map(\.active) == [false, true])
        #expect(rows[1].centre?.id == "C-WAKRA")
        #expect(rows[1].centreId == "C-WAKRA")
    }

    // Emergencies

    @Test(arguments: contractHarnesses, languages)
    func `an emergency stops the chat and gives no ticket`(
        harness: any ContractHarness, language: String
    ) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, raviQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        let reply = try await service.sendChat(visitId: visit, text: try #require(redFlag[language]))
        #expect(reply.emergency)
        #expect(reply.status == .redirectedEmergency)
        #expect(reply.reply.contains("999"))
        #expect(reply.aiSource == "rules")
        #expect(reply.nearestEd != nil)
        #expect(reply.intake == nil)

        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.stage == .emergency)
        #expect(stored.ticket == nil)
        #expect(stored.emergency?.reply == reply.reply)
        #expect(stored.emergency?.nearestEd == reply.nearestEd)

        let again = try await service.sendChat(visitId: visit, text: "ok")
        #expect(again.emergency)
        #expect(again.reply == reply.reply)
        #expect(try await service.getVisit(visitId: visit).chat.messages == stored.chat.messages)

        try await expectRefused(409, "intake_not_confirmed") {
            try await service.reserve(visitId: visit, centreId: "C-AIRPORT")
        }
        try await expectRefused(409, "visit_not_in_intake") {
            try await service.confirmIntake(visitId: visit, service: nil)
        }
        try await expectRefused(409, "no_reservation") {
            try await service.arrive(visitId: visit, body: .button)
        }
    }

    @Test(arguments: contractHarnesses)
    func `the override gives no ticket`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, raviQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(409, "not_emergency") {
            try await service.emergencyOverride(visitId: visit)
        }
        _ = try await service.sendChat(visitId: visit, text: try #require(redFlag["en"]))
        let answer = try await service.emergencyOverride(visitId: visit)
        #expect(answer.status == .redirectedEmergency)
        #expect(answer.ticket == nil)
        #expect(answer.message.contains("999"))
        #expect(answer.messageAr.contains("999"))
        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.stage == .emergency)
        #expect(stored.ticket == nil)
    }

    @Test(arguments: contractHarnesses)
    func `an emergency after a reservation takes the ticket away`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        let reply = try await service.sendChat(visitId: visit, text: try #require(redFlag["en"]))
        #expect(reply.emergency)
        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.stage == .emergency)
        #expect(stored.ticket == nil)
    }

    @Test(arguments: contractHarnesses)
    func `active_visit and emergency_today`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await reserved(service)
        let active = try await refusal { try await service.createVisit(patientId: nil) }
        #expect(active?.status == 409)
        #expect(active?.code == "active_visit")
        #expect(active?.extra["visit_id"] == .string(visit))

        try await signedIn(service, raviQid)
        let flagged = try await service.createVisit(patientId: nil).visitId
        _ = try await service.sendChat(visitId: flagged, text: try #require(redFlag["en"]))
        let stopped = try await refusal { try await service.createVisit(patientId: nil) }
        #expect(stopped?.status == 409)
        #expect(stopped?.code == "emergency_today")
        #expect(stopped?.messageAr != nil)
        #expect(stopped?.extra["visit_id"] == .string(flagged))
    }

    // Refill

    @Test(arguments: contractHarnesses, languages)
    func `the refill route gives no ticket`(harness: any ContractHarness, language: String) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, ahmedQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        let reply = try await service.sendChat(visitId: visit, text: try #require(refillAsk[language]))
        #expect(reply.refill != nil)
        #expect(reply.status == .deflectedRefill)
        #expect(!reply.emergency)
        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.stage == .refill)
        #expect(stored.ticket == nil)
        #expect(stored.refill == reply.refill)
        try await expectRefused(409, "intake_not_confirmed") {
            try await service.reserve(visitId: visit, centreId: "C-RAYYAN")
        }
    }

    @Test(arguments: contractHarnesses)
    func `I still want a visit carries on as GP`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, ahmedQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        try await expectRefused(409, "visit_not_deflected") {
            try await service.continueRefill(visitId: visit)
        }
        _ = try await service.sendChat(visitId: visit, text: try #require(refillAsk["en"]))
        let answer = try await service.continueRefill(visitId: visit)
        #expect(answer.status == .intake)
        #expect(answer.service == .gp)
        #expect(answer.intake != nil)
        let stored = try await service.getVisit(visitId: visit)
        #expect(stored.stage == .intake)
        #expect(stored.confirmedByPatient)
        #expect(stored.refill == nil)
        let arrived = try await service.reserve(visitId: visit, centreId: "C-RAYYAN")
        #expect(arrived.ticket.state == .reserved)
    }

    // Live updates

    @Test(.timeLimit(.minutes(1)), arguments: contractHarnesses)
    func `updates open, change and drop`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await confirmed(service)
        var updates = await service.visitUpdates(visitId: visit).makeAsyncIterator()
        #expect(await updates.next() == .open)

        _ = try await service.reserve(visitId: visit, centreId: "C-WAKRA")
        #expect(await updates.next() == .changed)

        try await harness.dropUpdates(service, visitId: visit)
        var last: VisitUpdate?
        while let update = await updates.next() { last = update }
        #expect(last == .dropped)
    }

    @Test(arguments: contractHarnesses)
    func `signing out forgets the session`(harness: any ContractHarness) async throws {
        let service = try await harness.makeService()
        try await signedIn(service, fatimaQid)
        let visit = try await service.createVisit(patientId: nil).visitId
        await service.signOut()
        #expect(await !service.isSignedIn)
        try await expectRefused(401, "unauthorized") { try await service.getMe() }
        try await expectRefused(401, "unauthorized") { try await service.getVisit(visitId: visit) }

        try await signedIn(service, fatimaQid)
        #expect(try await service.getVisit(visitId: visit).stage == .intake)
    }
}
