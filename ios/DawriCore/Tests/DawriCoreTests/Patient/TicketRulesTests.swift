import Foundation
import Testing
@testable import DawriCore

/// `NOW` in countdown.test.ts.
private let now = ClinicTime.parse("2026-11-06T10:00:00.000Z")!

private func visit(_ name: String = "visit_triage") throws -> Visit {
    try Fixture.decode(Visit.self, name)
}

private func ticketed(_ state: TicketState, number: String? = "T-014") throws -> Visit {
    var shown = try visit()
    shown.ticket?.state = state
    shown.ticket?.number = number
    return shown
}

@Suite("S09 countdown, every case of countdown.test.ts")
struct CountdownRulesTests {
    @Test(arguments: [
        (2700, "45:00"), (2699, "44:59"), (61, "01:01"), (60, "01:00"), (9, "00:09"), (0, "00:00"),
    ])
    func `formatCountdown shows the seconds as minutes and seconds, padded as the web`(
        seconds: Int, text: String
    ) {
        #expect(TicketRules.formatCountdown(seconds) == text)
    }

    @Test func `formatCountdown never goes below 00:00, and keeps minutes past an hour`() {
        #expect(TicketRules.formatCountdown(-5) == "00:00")
        #expect(TicketRules.formatCountdown(6000) == "100:00")
    }

    @Test func `secondsLeft reads the microseconds the backend writes`() {
        #expect(TicketRules.secondsLeft("2026-11-06T10:45:00.000000+00:00", now: now) == 2700)
        #expect(TicketRules.secondsLeft("2026-11-06T10:44:59.123456+00:00", now: now) == 2700)
    }

    @Test func `secondsLeft stays at 0 for a past expires_at`() throws {
        #expect(TicketRules.secondsLeft("2026-11-06T09:00:00.000000+00:00", now: now) == 0)
        let past = TicketRules.secondsLeft("2026-11-06T09:00:00+00:00", now: now)
        #expect(past == 0)
        let seconds = try #require(past)
        #expect(TicketRules.formatCountdown(seconds) == "00:00")
    }

    @Test func `secondsLeft gives 0 at the exact moment of expiry`() {
        #expect(TicketRules.secondsLeft("2026-11-06T10:00:00.000000+00:00", now: now) == 0)
    }

    @Test func `secondsLeft gives nil when there is no usable time`() {
        #expect(TicketRules.secondsLeft(nil, now: now) == nil)
        #expect(TicketRules.secondsLeft("soon", now: now) == nil)
    }

    @Test func `secondsLeft rounds a part second up, so the clock shows 00:01 until it is over`() {
        #expect(TicketRules.secondsLeft("2026-11-06T10:00:00.200000+00:00", now: now) == 1)
        #expect(TicketRules.secondsLeft("2026-11-06T13:00:00.500000+03:00", now: now) == 1)
    }

    @Test func `the check-in text says 45 minutes, and a fresh reservation starts at 45:00`() throws {
        let reserved = try Fixture.decode(ReserveResponse.self, "reserve")
        #expect(reserved.ticket.number == nil)
        #expect(reserved.ticket.peopleAhead == nil)
        #expect(reserved.checkInValidMin == 45)
        #expect(Strings.bundled.translate(.en, "reserved.valid") == "Check-in valid for 45 minutes")
        #expect(Strings.bundled.translate(.ar, "reserved.valid") == "تسجيل الوصول صالح لمدة 45 دقيقة")
        let end = try #require(ClinicTime.parse(reserved.expiresAt))
        let left = try #require(TicketRules.secondsLeft(reserved.expiresAt, now: end.addingTimeInterval(-45 * 60)))
        #expect(TicketRules.formatCountdown(left) == "45:00")
    }
}

@Suite("S10 live ticket, every non-DOM case of Ticket.test.tsx")
struct TicketScreenRulesTests {
    @Test func `shows an active ticket with all three rows`() throws {
        let active = try ticketed(.active)
        let ticket = try #require(TicketRules.shownTicket(active))
        #expect(ticket.number == "T-014")
        #expect(TicketRules.rows(for: ticket.state) == [.peopleAhead, .estimatedWait, .goTo])
    }

    @Test func `tells a called patient where to go, with no rows`() throws {
        let called = try ticketed(.called)
        #expect(TicketRules.shownTicket(called)?.state == .called)
        #expect(TicketRules.rows(for: .called).isEmpty)
        let line = Strings.bundled.translate(.en, "ticket.goNow", ["counter": "Triage 1"])
        #expect(line == "Go to Triage 1 now")
    }

    @Test func `says a serving patient is with the team, and keeps only where to go`() throws {
        #expect(TicketRules.shownTicket(try ticketed(.serving))?.state == .serving)
        #expect(TicketRules.rows(for: .serving) == [.goTo])
        #expect(Strings.bundled.translate(.en, "ticket.withTeam") == "You are with the team")
    }

    @Test(arguments: [TicketState.done, .released, .expired, .reserved])
    func `never leaves a blank screen for a finished or reserved ticket`(state: TicketState) throws {
        #expect(TicketRules.shownTicket(try ticketed(state)) == nil)
        #expect(Strings.bundled.translate(.en, "ticket.nextStep") == "Next step coming")
    }

    @Test func `keeps the steps between stages, when there is no ticket`() throws {
        var between = try visit("visit_doctor")
        between.ticket = nil
        #expect(TicketRules.shownTicket(between) == nil)
        #expect(between.stage == .doctor)
    }

    @Test func `shows the ticket of each stage with its own number`() throws {
        #expect(TicketRules.shownTicket(try visit("visit_doctor"))?.number?.hasPrefix("D-GP-") == true)
        #expect(TicketRules.shownTicket(try visit("visit_pharmacy"))?.number?.hasPrefix("P-") == true)
    }

    @Test func `reads the last update as Doha time, 24 hours, Latin digits`() throws {
        let stamp = try #require(ClinicTime.parse("2026-11-06T07:42:03Z"))
        #expect(TicketRules.dohaClock(stamp) == "10:42:03")
        let late = try #require(ClinicTime.parse("2026-11-06T21:05:09.999Z"))
        #expect(TicketRules.dohaClock(late) == "00:05:09")
        let line = "\(Strings.bundled.translate(.en, "ticket.slower")) \(Strings.bundled.translate(.en, "ticket.updatedAt")) 10:42:03"
        #expect(line == "Updates may be slower. Last updated 10:42:03")
    }

    @Test func `waits a moment before it says updates are slower`() {
        #expect(TicketRules.pollingNoticeDelay == .milliseconds(1_500))
    }

    @Test func `names a dependent, and nobody on the patient's own visit`() throws {
        let me = try Fixture.decode(Me.self, "me_with_dependents")
        let dependent = try #require(me.dependents.first)
        var theirs = try visit()
        theirs.patientId = dependent.id
        #expect(TicketRules.dependent(of: theirs, in: me)?.id == dependent.id)
        let line = Strings.bundled.translate(.en, "ticket.forPerson", ["name": nameOf(dependent, lang: .en)])
        #expect(line == "Visit for \(dependent.fullNameEn)")

        var own = try visit()
        own.patientId = me.patient.id
        #expect(TicketRules.dependent(of: own, in: me) == nil)
        #expect(TicketRules.dependent(of: theirs, in: nil) == nil)
    }
}

@Suite("S11 visit complete, every non-DOM case of Complete.test.tsx")
struct CompleteRulesTests {
    @Test func `renders medicines in English, exactly as the server wrote them`() throws {
        let done = try visit("visit_completed")
        let lines = TicketRules.medicines(done, lang: .en)
        #expect(!lines.isEmpty)
        for line in lines {
            let split = TicketRules.splitLine(line)
            #expect(line.line == "\(split.heading): \(split.directions)")
        }
        #expect(TicketRules.splitLine(lines[0]).heading == "Paracetamol (tablet)")
    }

    @Test func `renders medicines in Arabic from the Arabic list`() throws {
        let done = try visit("visit_completed")
        #expect(TicketRules.medicines(done, lang: .ar) == done.medicines.ar)
        #expect(TicketRules.medicines(done, lang: .ar) != done.medicines.en)
    }

    @Test func `splits at the first colon only, and trims the directions`() {
        let line = MedicineLine(drug: "DR-X", name: "X", line: "Name:  take at 08:00, then 20:00 ")
        #expect(TicketRules.splitLine(line) == ("Name", "take at 08:00, then 20:00"))
    }

    @Test func `with no colon, the name heads the line`() {
        let line = MedicineLine(drug: "DR-X", name: "Paracetamol", line: "take 500 mg")
        #expect(TicketRules.splitLine(line) == ("Paracetamol", "take 500 mg"))
    }

    @Test func `says so when nothing was prescribed`() throws {
        var done = try visit("visit_completed")
        done.medicines = VisitMedicines(en: [], ar: [])
        #expect(TicketRules.medicines(done, lang: .en).isEmpty)
        #expect(Strings.bundled.translate(.en, "complete.noMedicines") == "No medicines were prescribed")
    }

    @Test func `carries the fixed follow-up line with 999`() {
        let line = Strings.bundled.translate(.en, "complete.followUpLine", ["phone": 999])
        #expect(line.contains("call 999 in an emergency"))
    }

    @Test func `refetches on already_rated, and shows any other failure`() {
        #expect(TicketRules.ratingNeedsRefetch(ClinicError(status: 409, code: "already_rated", message: "")))
        #expect(!TicketRules.ratingNeedsRefetch(ClinicError.network))
        #expect(!TicketRules.ratingNeedsRefetch(CancellationError()))
    }
}

@Suite("S08 centre choice, every non-DOM case of Centre.test.tsx")
struct CentreRulesTests {
    private func list(_ name: String = "centre_list") throws -> CentreList {
        try Fixture.decode(CentreList.self, name)
    }

    @Test func `preselects the registered centre`() throws {
        let centres = try list()
        let registered = try #require(centres.centres.first { $0.registered })
        #expect(centres.defaultCentreId == registered.id)
        #expect(TicketRules.selected(picked: nil, list: centres)?.id == registered.id)
    }

    @Test func `preselects nothing when the registered centre lacks the service`() throws {
        var centres = try list()
        centres.defaultCentreId = nil
        #expect(TicketRules.selected(picked: nil, list: centres) == nil)
    }

    @Test func `lists the registered centre first, and keeps the rest in order`() throws {
        var centres = try list().centres
        centres.reverse()
        let ordered = TicketRules.ordered(centres)
        #expect(ordered.first?.registered == true)
        #expect(ordered.dropFirst().map(\.id) == centres.filter { !$0.registered }.map(\.id))
    }

    @Test func `the suggestion does not change the preselected centre`() throws {
        let centres = try list("centre_list_suggestion")
        let suggestion = try #require(centres.suggestion)
        #expect(TicketRules.selectedId(picked: nil, list: centres) != suggestion.centreId)
        #expect(TicketRules.offersSuggestion(centres, picked: nil))
    }

    @Test func `moves the selection only when the patient chooses it`() throws {
        let centres = try list("centre_list_suggestion")
        let suggestion = try #require(centres.suggestion)
        #expect(TicketRules.selectedId(picked: suggestion.centreId, list: centres) == suggestion.centreId)
        #expect(!TicketRules.offersSuggestion(centres, picked: suggestion.centreId))
    }

    @Test func `uses the Arabic reason in Arabic`() throws {
        let suggestion = try #require(try list("centre_list_suggestion").suggestion)
        #expect(TicketRules.reason(suggestion, lang: .ar) == suggestion.reasonAr)
        #expect(TicketRules.reason(suggestion, lang: .en) == suggestion.reasonEn)
    }

    @Test(arguments: ["active_visit", "emergency_today"])
    func `follows a refusal to the other visit`(code: String) {
        let error = ClinicError(status: 409, code: code, message: code, extra: ["visit_id": .string("V9")])
        let expected: TicketRules.Elsewhere =
            code == "emergency_today" ? .emergency(visitId: "V9") : .visit(id: "V9")
        #expect(TicketRules.elsewhere(after: error) == expected)
    }

    @Test func `shows any other refusal in the panel`() {
        #expect(TicketRules.elsewhere(after: ClinicError.network) == nil)
        let noId = ClinicError(status: 409, code: "active_visit", message: "")
        #expect(TicketRules.elsewhere(after: noId) == nil)
        let other = ClinicError(status: 409, code: "service_not_offered", message: "", extra: ["visit_id": .string("V9")])
        #expect(TicketRules.elsewhere(after: other) == nil)
    }
}

@Suite("S09 arrival, every non-DOM case of Reserved.test.tsx")
struct ArrivalRulesTests {
    @Test func `gives the distance and the limit when too far`() {
        let error = ClinicError(status: 409, code: "too_far", message: "", extra: ["distance_m": .number(5234)])
        #expect(TicketRules.arrivalFailure(error) == .tooFar(metres: 5234))
        let line = Strings.bundled.translate(
            .en, "reserved.tooFar", ["distance": 5234, "limit": TicketRules.geofenceMetres])
        #expect(line == "You are 5234 m from the centre, and check-in works within 150 m.")
    }

    @Test func `a too_far with no distance is an ordinary failure`() {
        #expect(TicketRules.arrivalFailure(ClinicError(status: 409, code: "too_far", message: "")) == .failed)
    }

    @Test func `refetches on ticket_expired`() {
        #expect(TicketRules.arrivalFailure(ClinicError(status: 409, code: "ticket_expired", message: "")) == .refetch)
    }

    @Test func `moves to the emergency visit on emergency_today`() {
        let error = ClinicError(
            status: 409, code: "emergency_today", message: "", extra: ["visit_id": .string("V2")])
        #expect(TicketRules.arrivalFailure(error) == .emergency(visitId: "V2"))
        #expect(TicketRules.arrivalFailure(ClinicError(status: 409, code: "emergency_today", message: "")) == .failed)
    }

    @Test func `puts a wrong door under the field, and anything else in a block`() {
        #expect(TicketRules.arrivalFailure(ClinicError(status: 409, code: "wrong_door", message: "")) == .wrongDoor)
        #expect(TicketRules.arrivalFailure(ClinicError.network) == .failed)
        #expect(TicketRules.arrivalFailure(CancellationError()) == .failed)
    }

    @Test func `reads a door code however it was typed`() {
        #expect(TicketRules.doorCode("  door-c-wakra \n") == "DOOR-C-WAKRA")
        #expect(TicketRules.doorCode("DOOR-٤٥۶") == "DOOR-456")
        #expect(TicketRules.doorCode("") == "")
    }

    @Test func `checks in within 150 m and reads again every 5 seconds at 00:00`() {
        #expect(TicketRules.geofenceMetres == 150)
        #expect(TicketRules.expiryRetry == .seconds(5))
    }
}
