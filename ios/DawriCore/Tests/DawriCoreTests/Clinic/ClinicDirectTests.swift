import Foundation
import Testing
@testable import DawriCore

private let triage = "C-WAKRA-T1"
private let roomFour = "C-WAKRA-D4"
private let pharmacy = "C-WAKRA-P1"
private let fatima = "P001"
private let layla = "P004"

private func refusal(_ code: String, _ body: () throws -> Void) {
    do {
        try body()
        Issue.record("Expected \(code)")
    } catch let error as ClinicError {
        #expect(error.code == code)
    } catch {
        Issue.record("Unexpected \(error)")
    }
}

@Suite("Clinic demo journey")
struct ClinicJourneyTests {
    private func walk(simulateLoad: Bool) throws {
        var clinic = try ClinicFixture(simulateLoad: simulateLoad)
        let visit = clinic.newVisit(fatima)
        let reserved = try clinic.engine.issueTicket(
            &clinic.state, visitId: visit, counterId: triage)
        let first = try clinic.engine.activate(&clinic.state, ticketId: reserved.id)
        #expect(first.number == "T-014")

        let called = try #require(try clinic.engine.callNext(&clinic.state, counterId: triage).called)
        #expect(called.id == first.id)
        _ = try clinic.engine.serve(&clinic.state, ticketId: called.id)
        let doctor = try clinic.engine.advance(
            &clinic.state, ticketId: called.id, nextCounterId: roomFour)
        #expect(doctor.number == "D-GP-023")

        _ = try clinic.engine.callNext(&clinic.state, counterId: roomFour)
        let chemist = try clinic.engine.advance(
            &clinic.state, ticketId: doctor.id, nextCounterId: pharmacy)
        #expect(chemist.number == "P-031")

        _ = try clinic.engine.callNext(&clinic.state, counterId: pharmacy)
        let done = try clinic.engine.finishVisit(&clinic.state, ticketId: chemist.id)
        #expect(done.state == .done)
        #expect(clinic.state.visit(visit)?.status == .completed)
    }

    @Test func `Fatima gets T-014, D-GP-023 and P-031 on a fresh seed with load`() throws {
        try walk(simulateLoad: true)
    }

    @Test func `the numbers land the same without load`() throws {
        try walk(simulateLoad: false)
    }

    @Test func `three simulated patients are ahead at Al Wakra triage`() throws {
        var clinic = try ClinicFixture()
        let wait = try clinic.engine.counterWait(clinic.state, counterId: triage)
        #expect(wait == QueueWait(peopleAhead: 3, waitMin: 12))

        let visit = clinic.newVisit(fatima)
        let reserved = try clinic.engine.issueTicket(
            &clinic.state, visitId: visit, counterId: triage)
        let active = try clinic.engine.activate(&clinic.state, ticketId: reserved.id)
        let view = try clinic.engine.ticketView(&clinic.state, ticket: active)
        #expect(view.peopleAhead == 3)
        #expect(view.estWaitMin == 12)
        #expect(view.expiresAt == nil)
        #expect(view.counter == "Triage 1")
        #expect(view.counterAr == clinic.state.counter(triage)?.labelAr)
    }

    @Test func `a reserved ticket has no number, no seq and no place`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let reserved = try clinic.engine.issueTicket(
            &clinic.state, visitId: visit, counterId: triage)
        #expect(reserved.number == nil)
        #expect(reserved.seq == nil)
        let view = try clinic.engine.ticketView(&clinic.state, ticket: reserved)
        #expect(view.state == .reserved)
        #expect(view.number == nil)
        #expect(view.peopleAhead == nil)
        #expect(view.estWaitMin == nil)
        #expect(view.expiresAt == "2026-11-07T09:45:00.000000+00:00")
    }

    @Test func `a real ticket is called past the simulated ones ahead of it`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: triage)
        let result = try clinic.engine.callNext(&clinic.state, counterId: triage)
        #expect(result.called?.id == ticket.id)
        #expect(result.autoCompleted.count == 3)
        #expect(result.autoCompleted.allSatisfy { $0.simulated && $0.state == .done })
    }

    @Test func `waiting patients are told when the queue moves`() throws {
        var clinic = try ClinicFixture()
        let first = clinic.newVisit(fatima)
        let second = clinic.newVisit("P006")
        _ = try clinic.engine.issueActive(&clinic.state, visitId: first, counterId: triage)
        let other = try clinic.engine.issueActive(&clinic.state, visitId: second, counterId: triage)
        _ = clinic.engine.takeMessages()

        _ = try clinic.engine.callNext(&clinic.state, counterId: triage)
        let messages = clinic.engine.takeMessages()
        let changed = messages.filter {
            $0.visitId == second && $0.event.object?["type"]?.string == "queue.changed"
        }
        #expect(changed.count == 1)
        #expect(!messages.contains {
            $0.visitId == other.visitId && $0.event.object?["type"]?.string == "ticket.called"
        })
        #expect(messages.contains {
            $0.visitId == first && $0.event.object?["type"]?.string == "ticket.called"
        })
        #expect(clinic.engine.takeMessages().isEmpty)
    }
}

@Suite("Clinic expiry")
struct ClinicExpiryTests {
    private func reserved() throws -> (ClinicFixture, String, TicketRecord) {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueTicket(&clinic.state, visitId: visit, counterId: triage)
        _ = clinic.engine.takeMessages()
        return (clinic, visit, ticket)
    }

    @Test func `a reservation stands at 44:59.999999`() throws {
        var (clinic, visit, ticket) = try reserved()
        clinic.clock.advance(microseconds: 2_699_999_999)
        #expect(try clinic.engine.expireDue(&clinic.state).isEmpty)
        let active = try clinic.engine.activate(&clinic.state, ticketId: ticket.id)
        #expect(active.state == .active)
        #expect(clinic.state.visit(visit)?.status == .inTriage)
    }

    @Test func `a reservation lapses at exactly 45:00`() throws {
        var (clinic, visit, ticket) = try reserved()
        clinic.clock.advance(microseconds: 2_700_000_000)
        let expired = try clinic.engine.expireDue(&clinic.state)
        #expect(expired.map(\.id) == [ticket.id])
        #expect(expired.first?.state == .released)
        #expect(clinic.state.visit(visit)?.status == .expired)
    }

    @Test func `activate commits the lapse and still refuses with 410`() throws {
        var (clinic, visit, ticket) = try reserved()
        clinic.clock.advance(microseconds: 2_700_000_000)
        do {
            _ = try clinic.engine.activate(&clinic.state, ticketId: ticket.id)
            Issue.record("Expected a refusal")
        } catch let error as ClinicError {
            #expect(error.code == "ticket_expired")
            #expect(error.status == 410)
        }
        #expect(clinic.state.ticket(ticket.id)?.state == .released)
        #expect(clinic.state.visit(visit)?.status == .expired)
        let messages = clinic.engine.takeMessages()
        #expect(messages.contains {
            $0.visitId == visit && $0.event.object?["type"]?.string == "ticket.released"
        })
    }

    @Test func `live_ticket does not expire, so activate can answer 410`() throws {
        let (clinic, visit, ticket) = try reserved()
        clinic.clock.advance(seconds: 3_600)
        #expect(clinic.engine.liveTicket(clinic.state, visitId: visit)?.id == ticket.id)
    }

    @Test func `a ticket released in time is invalid and not expired`() throws {
        var (clinic, _, ticket) = try reserved()
        _ = try clinic.engine.release(&clinic.state, ticketId: ticket.id, reason: "cancelled")
        clinic.clock.advance(seconds: 2_800)
        refusal("invalid_transition") {
            _ = try clinic.engine.activate(&clinic.state, ticketId: ticket.id)
        }
    }
}

@Suite("Clinic refusals and rollback")
struct ClinicRefusalTests {
    @Test func `each queue error has the backend's status`() {
        #expect(ClinicError.ticketNotFound("").status == 404)
        #expect(ClinicError.ticketExpired("").status == 410)
        #expect(ClinicError.invalidTransition("").status == 409)
        #expect(ClinicError.visitNotEligible("").status == 409)
        #expect(ClinicError.visitHasLiveTicket("").status == 409)
        #expect(ClinicError.counterBusy("").status == 409)
    }

    @Test func `a refused advance leaves the ticket where it was`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: triage)
        _ = try clinic.engine.callNext(&clinic.state, counterId: triage)
        _ = clinic.engine.takeMessages()
        let before = clinic.state

        refusal("invalid_transition") {
            _ = try clinic.engine.advance(
                &clinic.state, ticketId: ticket.id, nextCounterId: "C-RAYYAN-D1")
        }
        #expect(clinic.state == before)
        #expect(clinic.engine.takeMessages().isEmpty)
    }

    @Test func `finishing a visit never reopens an emergency`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: triage)
        _ = try clinic.engine.callNext(&clinic.state, counterId: triage)
        clinic.state.updateVisit(visit) { $0.status = .redirectedEmergency }
        refusal("visit_not_eligible") {
            _ = try clinic.engine.finishVisit(&clinic.state, ticketId: ticket.id)
        }
        #expect(clinic.state.visit(visit)?.status == .redirectedEmergency)
        #expect(clinic.state.ticket(ticket.id)?.state == .called)
    }

    @Test func `the refusal texts are the backend's`() throws {
        var clinic = try ClinicFixture()
        do {
            _ = try clinic.engine.serve(&clinic.state, ticketId: "tkt_nope")
            Issue.record("Expected a refusal")
        } catch let error as ClinicError {
            #expect(error.message == "no ticket tkt_nope")
        }
    }
}

@Suite("Clinic simulated load")
struct ClinicLoadTests {
    @Test func `a tick leaves protected centres alone and keeps the rest within one`() throws {
        var clinic = try ClinicFixture()
        let wakra = clinic.state.tickets.filter { $0.centreId == "C-WAKRA" }
        let sequences = clinic.state.sequences.filter { $0.centreId == "C-WAKRA" }
        for _ in 0..<7 {
            try SimulatedLoad.tick(&clinic.engine, &clinic.state)
            clinic.clock.advance(seconds: 60)
            for row in SimulatedLoad.tickCounters(clinic.state) {
                #expect(abs(row.waiting - row.target) <= 1, "\(row.counterId)")
            }
        }
        #expect(clinic.state.tickets.filter { $0.centreId == "C-WAKRA" } == wakra)
        #expect(clinic.state.sequences.filter { $0.centreId == "C-WAKRA" } == sequences)
        #expect(!SimulatedLoad.tickCounters(clinic.state).contains { $0.counterId == triage })
        #expect(SimulatedLoad.tickCounters(clinic.state).count == 4)
    }

    @Test func `T-014 survives any number of ticks`() throws {
        var clinic = try ClinicFixture()
        for _ in 0..<5 { try SimulatedLoad.tick(&clinic.engine, &clinic.state) }
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: triage)
        #expect(ticket.number == "T-014")
    }

    @Test func `seeding leaves nothing to publish`() throws {
        let clinic = try ClinicFixture()
        #expect(clinic.engine.outbox.isEmpty)
    }

    @Test func `a state is stale unless today is its only day`() throws {
        let clinic = try ClinicFixture()
        #expect(!clinic.state.isStale(today: "2026-11-07"))
        #expect(clinic.state.isStale(today: "2026-11-08"))
        #expect(ClinicState().isStale(today: "2026-11-07"))
        var mixed = clinic.state
        mixed.sequences.append(
            NumberSequenceRecord(centreId: "C-WAKRA", prefix: "T", day: "2026-11-08", lastValue: 1))
        #expect(mixed.isStale(today: "2026-11-07"))
    }

    @Test func `a state survives a trip through JSON`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: triage)
        _ = try clinic.engine.callNext(&clinic.state, counterId: triage)
        _ = try clinic.engine.complete(&clinic.state, ticketId: ticket.id)
        let saved = try JSONEncoder().encode(clinic.state)
        #expect(try JSONDecoder().decode(ClinicState.self, from: saved) == clinic.state)
    }
}

@Suite("Clinic visit flow")
struct ClinicVisitFlowTests {
    @Test func `a red flag takes every live ticket of the patient, and no one else's`() throws {
        var clinic = try ClinicFixture()
        let first = clinic.newVisit(fatima)
        let second = clinic.newVisit(fatima)
        let child = clinic.newVisit(layla)
        let serving = try clinic.engine.issueActive(&clinic.state, visitId: first, counterId: triage)
        _ = try clinic.engine.callNext(&clinic.state, counterId: triage)
        _ = try clinic.engine.serve(&clinic.state, ticketId: serving.id)
        let held = try clinic.engine.issueTicket(&clinic.state, visitId: second, counterId: triage)
        let theirs = try clinic.engine.issueActive(&clinic.state, visitId: child, counterId: triage)

        try VisitFlow.leaveTheQueue(&clinic.engine, &clinic.state, patientId: fatima)

        #expect(clinic.engine.liveTicketsOfPatient(clinic.state, patientId: fatima).isEmpty)
        #expect(clinic.state.ticket(serving.id)?.state == .released)
        #expect(clinic.state.ticket(held.id)?.state == .released)
        #expect(clinic.state.visit(first)?.status == .redirectedEmergency)
        #expect(clinic.state.visit(second)?.status == .redirectedEmergency)
        #expect(clinic.state.ticket(theirs.id)?.state == .active)
        #expect(clinic.state.visit(child)?.status == .inTriage)
    }

    @Test func `an emergency counts on the Doha day it happened`() throws {
        // 23:50 in Doha, and the flag lands twenty minutes later, on the next Doha day.
        var clinic = try ClinicFixture(start: "2026-11-07T20:50:00.000000+00:00")
        let visit = clinic.newVisit(fatima, status: .redirectedEmergency)
        let evening = clinic.clock.now
        #expect(VisitFlow.emergencyToday(clinic.state, patientId: fatima, now: evening) == visit)

        clinic.clock.advance(seconds: 1_200)
        clinic.state.appendEvent(
            visitId: visit, type: "redflag.hit", payload: .object([:]),
            at: ClinicTime.iso(clinic.clock.now))
        let next = clinic.clock.now
        #expect(VisitFlow.emergencyToday(clinic.state, patientId: fatima, now: evening) == nil)
        #expect(VisitFlow.emergencyToday(clinic.state, patientId: fatima, now: next) == visit)
        #expect(
            VisitFlow.emergencyToday(clinic.state, patientId: fatima, now: next, otherThan: visit)
                == nil)
    }

    @Test func `a stopped dependent leaves the guardian free`() throws {
        var clinic = try ClinicFixture()
        _ = clinic.newVisit(layla, status: .redirectedEmergency)
        let now = clinic.clock.now
        #expect(VisitFlow.emergencyToday(clinic.state, patientId: fatima, now: now) == nil)
        #expect(VisitFlow.emergencyToday(clinic.state, patientId: layla, now: now) != nil)
    }

    @Test func `other events on the visit say nothing about when it happened`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima, status: .redirectedEmergency)
        clinic.clock.advance(seconds: 86_400)
        clinic.state.appendEvent(
            visitId: visit, type: "emergency.override", payload: .object([:]),
            at: ClinicTime.iso(clinic.clock.now))
        let now = clinic.clock.now
        #expect(VisitFlow.emergencyToday(clinic.state, patientId: fatima, now: now) == nil)
    }

    @Test func `the demo prescription gives Fatima no penicillin, in plain language`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let patient = try #require(clinic.state.patient(fatima))
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: roomFour)
        _ = try clinic.engine.callNext(&clinic.state, counterId: roomFour)

        for index in clinic.state.drugs.indices where clinic.state.drugs[index].id == "DR-AMOX" {
            clinic.state.drugs[index].demoDefault = 1
        }
        let items = try VisitFlow.defaultItems(clinic.state, allergies: patient.allergies)
        #expect(items.map(\.drug.id) == ["DR-DEXT", "DR-PARA"])

        let next = try VisitFlow.completeConsult(
            &clinic.engine, &clinic.state, visitId: visit, ticket: ticket, items: items,
            actor: "S-WAK-DOC2")
        #expect(next.counterId == pharmacy)
        #expect(clinic.state.visit(visit)?.status == .inPharmacy)

        let english = MedicineLines.forVisit(clinic.state, visitId: visit, lang: "en")
        #expect(english.map(\.drug) == ["DR-DEXT", "DR-PARA"])
        #expect(english.map(\.line) == [
            "Dextromethorphan syrup: take 10 ml, every 8 hours when needed, for 3 days.",
            "Paracetamol (tablet): take 500 mg, every 6 hours when needed, for 3 days.",
        ])
        #expect(MedicineLines.forVisit(clinic.state, visitId: visit, lang: "ar").count == 2)

        _ = try clinic.engine.callNext(&clinic.state, counterId: pharmacy)
        let done = try VisitFlow.dispense(
            &clinic.engine, &clinic.state, visitId: visit, ticket: next, actor: "S-WAK-PHARM1")
        #expect(done.state == .done)
        #expect(clinic.state.visit(visit)?.status == .completed)
        let types = clinic.state.events.filter { $0.visitId == visit }.map(\.type)
        #expect(types.contains("consult.done"))
        #expect(types.contains("dispensed"))
    }

    @Test func `an acknowledged conflict is logged, and an empty consult ends the visit`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let patient = try #require(clinic.state.patient(fatima))
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: roomFour)
        _ = try clinic.engine.callNext(&clinic.state, counterId: roomFour)
        let items = try VisitFlow.resolveItems(
            clinic.state, items: [PrescriptionRequest(drugId: "DR-AMOX", notes: "  ")])
        #expect(items.first?.notes == nil)
        #expect(items.first?.dose == "500 mg")
        let conflicts = VisitFlow.allergyConflicts(allergies: patient.allergies, items: items)
        #expect(conflicts.map(\.drugId) == ["DR-AMOX"])
        #expect(conflicts.first?.conflict.textEn
            == "Allergy on record: penicillin. Check before prescribing amoxicillin.")

        let finished = try VisitFlow.completeConsult(
            &clinic.engine, &clinic.state, visitId: visit, ticket: ticket, items: [],
            actor: "S-WAK-DOC2", overrides: conflicts)
        #expect(finished.state == .done)
        #expect(clinic.state.visit(visit)?.status == .completed)
        #expect(clinic.state.events.contains { $0.type == "prescription.allergy_override" })
    }

    @Test func `a consult needs the patient at the counter`() throws {
        var clinic = try ClinicFixture()
        let visit = clinic.newVisit(fatima)
        let ticket = try clinic.engine.issueActive(&clinic.state, visitId: visit, counterId: roomFour)
        refusal("invalid_transition") {
            _ = try VisitFlow.completeConsult(
                &clinic.engine, &clinic.state, visitId: visit, ticket: ticket, items: [],
                actor: "S-WAK-DOC2")
        }
        #expect(clinic.state.prescriptions.isEmpty)
        #expect(!clinic.state.events.contains { $0.type == "consult.done" })
    }

    @Test func `an unknown drug is a 422`() {
        let state = ClinicState()
        do {
            _ = try VisitFlow.resolveItems(state, items: [PrescriptionRequest(drugId: "DR-NOPE")])
            Issue.record("Expected a refusal")
        } catch let error as ClinicError {
            #expect(error.status == 422)
            #expect(error.code == "unknown_drug")
        } catch {
            Issue.record("Unexpected \(error)")
        }
    }

    @Test func `an allergen with no Arabic stays as stored`() throws {
        let state = ClinicState()
        let drug = try #require(state.drugs.first { $0.id == "DR-PARA" })
        var tagged = drug
        tagged.allergyTags = ["Sulfa "]
        let conflict = try #require(
            VisitFlow.allergyConflict(allergies: [" SULFA"], drug: tagged))
        #expect(conflict.allergen == " SULFA")
        #expect(conflict.textAr.contains(" SULFA"))
    }

    @Test func `a substring of the English name counts as a hit`() throws {
        let state = ClinicState()
        let drug = try #require(state.drugs.first { $0.id == "DR-AMOX" })
        #expect(VisitFlow.allergyConflict(allergies: ["AMOX"], drug: drug) != nil)
        #expect(VisitFlow.allergyConflict(allergies: ["  "], drug: drug) == nil)
    }
}

@Suite("Clinic Python text behaviour")
struct ClinicTextTests {
    /// Each value from `round()` in Python.
    @Test(arguments: [
        (0.25, 0.2), (0.35, 0.3), (0.15, 0.1), (1.05, 1.1), (2.25, 2.2), (9.45, 9.4), (0.05, 0.1),
        (1234.55, 1234.5), (0.0, 0.0),
    ])
    func `tenths round the exact binary value`(value: Double, expected: Double) {
        #expect(ClinicText.roundedToTenth(value) == expected)
    }

    @Test(arguments: [(0.5, 0), (1.5, 2), (2.5, 2), (149.5, 150), (150.5, 150)])
    func `metres round half to even`(value: Double, expected: Int) {
        #expect(ClinicGeo.roundedMetres(value) == expected)
    }

    @Test func `strip takes what Python takes and no more`() {
        #expect(ClinicText.strip("\u{1C}\u{1F}\u{85}\u{A0} x\t\n\u{3000}") == "x")
        #expect(ClinicText.strip("\u{200B}x") == "\u{200B}x")
        #expect(ClinicText.strip(" \t ") == "")
    }

    @Test func `the first letter is a code point, not a grapheme`() {
        #expect(sameScalars(ClinicText.capitalisedFirst("e\u{301}x"), "E\u{301}x"))
        #expect(ClinicText.capitalisedFirst("\u{DF}x") == "SSx")
        #expect(ClinicText.capitalisedFirst("\u{1F600}x") == "\u{1F600}x")
        #expect(ClinicText.capitalisedFirst("") == "")
    }

    @Test func `containment goes by scalars`() {
        #expect(ClinicText.contains("abc", "bc"))
        #expect(ClinicText.contains("abc", ""))
        #expect(!ClinicText.contains("\u{E9}", "e\u{301}"))
        #expect(ClinicText.contains("e\u{301}", "e"))
        #expect(!ClinicText.contains("ab", "abc"))
    }

    @Test func `a value that holds a placeholder is not filled again`() {
        let filled = ClinicText.fill("{a} {b} {c}", ["a": "{b}", "b": "x"])
        #expect(filled == "{b} x {c}")
    }

    @Test func `the Doha day ignores the device zone`() throws {
        let late = try #require(ClinicTime.parse("2026-11-07T20:59:59.999999+00:00"))
        let midnight = try #require(ClinicTime.parse("2026-11-07T21:00:00+00:00"))
        #expect(ClinicTime.dohaDay(late) == "2026-11-07")
        #expect(ClinicTime.dohaDay(midnight) == "2026-11-08")
    }

    @Test func `the dose unit comes from the exported pattern`() {
        let line = MedicineLines.plainLine(
            MedicineItem(drug: "x", dose: "5 MG and 500mgs"), lang: "ar")
        let expected = ClinicData.bundled.text.medicines.unitAr.value(for: "mg") ?? ""
        #expect(line.contains("5 \(expected)"))
        #expect(line.contains("500mgs"))
    }

    @Test func `a frequency outside the table is copied as written`() {
        let line = MedicineLines.plainLine(
            MedicineItem(drug: "x", frequency: "When You Need It"), lang: "en")
        #expect(line == "x: When You Need It.")
    }
}
