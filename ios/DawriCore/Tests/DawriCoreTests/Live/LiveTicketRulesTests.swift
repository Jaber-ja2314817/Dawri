import Foundation
import Testing
@testable import DawriCore

/// Every case here runs at this moment.
let liveNow = ClinicTime.parse("2026-11-07T09:10:00.000Z")!

func liveVisit(_ name: String = "visit_triage") throws -> Visit {
    try Fixture.decode(Visit.self, name)
}

/// Fatima's triage visit with its ticket in `state`, or with no ticket at all.
func liveVisit(ticket state: TicketState?, number: String? = "T-014") throws -> Visit {
    var visit = try liveVisit()
    if let state {
        visit.ticket?.state = state
        visit.ticket?.number = number
    } else {
        visit.ticket = nil
    }
    return visit
}

func running(
    _ visit: Visit, lang: Lang = .en, staleDate: Date? = nil, edit: (inout TicketLiveState) -> Void = { _ in }
) -> LiveTicketRunning {
    var state = LiveTicketRules.state(for: visit, lang: lang)
    edit(&state)
    return LiveTicketRunning(visitId: visit.visitId, lang: lang, state: state, staleDate: staleDate)
}

@Suite("Live: TicketLiveState fields")
struct TicketLiveStateTests {
    @Test func `the state carries the ticket state and the centre, and stays plain data`() throws {
        let state = TicketLiveState(
            number: "T-014", stage: .triage, peopleAhead: 3, estWaitMin: 12, counter: "Triage 1",
            ticketState: .called, centreName: "Al Wakra Health Centre")
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(TicketLiveState.self, from: data)
        #expect(back == state)
        #expect(back.ticketState == .called)
        #expect(back.centreName == "Al Wakra Health Centre")
        #expect(Set([state, back]).count == 1)
        var other = state
        other.ticketState = .active
        #expect(other != state)
        other = state
        other.centreName = "مركز الوكرة الصحي"
        #expect(other != state)
    }

    @Test func `between stages the ticket state is nil, and the old initialiser still works`() throws {
        let state = TicketLiveState(
            number: nil, stage: .doctor, peopleAhead: nil, estWaitMin: nil, counter: "")
        #expect(state.ticketState == nil)
        #expect(state.centreName == "")
        let back = try JSONDecoder().decode(TicketLiveState.self, from: JSONEncoder().encode(state))
        #expect(back == state)
    }

    @Test func `the state is read from the visit in each language`() throws {
        let visit = try liveVisit()
        let en = LiveTicketRules.state(for: visit, lang: .en)
        #expect(en == TicketLiveState(
            number: "T-014", stage: .triage, peopleAhead: 3, estWaitMin: 12, counter: "Triage 1",
            ticketState: .active, centreName: "Al Wakra Health Centre"))
        let ar = LiveTicketRules.state(for: visit, lang: .ar)
        #expect(ar.counter == "الفرز 1")
        #expect(ar.centreName == "مركز الوكرة الصحي")
        #expect(ar.number == "T-014")
    }

    @Test func `a ticket with no number, or none at all, is between stages`() throws {
        for visit in [try liveVisit(ticket: .active, number: nil), try liveVisit(ticket: nil)] {
            let state = LiveTicketRules.state(for: visit, lang: .en)
            #expect(state.number == nil)
            #expect(state.ticketState == nil)
            #expect(state.peopleAhead == nil)
            #expect(LiveTicketRules.phase(state) == .between)
        }
    }

    @Test(arguments: [
        (TicketState.active, LiveTicketPhase.active), (.called, .called), (.serving, .serving),
    ])
    func `the phase follows the ticket`(ticket: TicketState, phase: LiveTicketPhase) throws {
        let state = LiveTicketRules.state(for: try liveVisit(ticket: ticket), lang: .en)
        #expect(LiveTicketRules.phase(state) == phase)
    }

    @Test func `the final state is complete, with no number`() throws {
        let final = LiveTicketRules.finalState(for: try liveVisit("visit_completed"), lang: .en)
        #expect(final.number == nil)
        #expect(final.stage == .completed)
        #expect(LiveTicketRules.phase(final) == .ended)
    }
}

@Suite("Live: LiveTicketRules")
struct LiveTicketRulesTests {
    private let later = liveNow.addingTimeInterval(15)

    // No activity

    @Test(arguments: [
        "visit_reserved", "visit_emergency", "visit_refill", "visit_refill_continued",
        "visit_expired", "visit_cancelled", "visit_intake", "visit_intake_confirmed",
    ])
    func `nothing starts while reserved, on an emergency, a refill, or a visit that is over`(
        name: String
    ) throws {
        let visit = try liveVisit(name)
        for lang in Lang.allCases {
            #expect(LiveTicketRules.decide(
                visit: visit, lang: lang, now: liveNow, nextStepAt: later, running: nil) == .none)
        }
    }

    @Test func `a reserved ticket has no number, so nothing starts from it`() throws {
        let visit = try liveVisit("visit_reserved")
        #expect(visit.ticket?.number == nil)
        #expect(!LiveTicketRules.isLive(visit))
    }

    @Test func `nothing starts between stages, before the next number exists`() throws {
        for visit in [try liveVisit(ticket: nil), try liveVisit(ticket: .active, number: nil)] {
            #expect(LiveTicketRules.decide(
                visit: visit, lang: .en, now: liveNow, nextStepAt: later, running: nil) == .none)
        }
    }

    // Start

    @Test func `an active ticket with a number starts it, stale at the next planned step`() throws {
        let visit = try liveVisit()
        let decision = LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: later, running: nil)
        #expect(decision == .start(LiveTicketRules.state(for: visit, lang: .en), staleDate: later))
    }

    @Test func `it starts in the language asked for`() throws {
        let visit = try liveVisit()
        guard case .start(let state, _) = LiveTicketRules.decide(
            visit: visit, lang: .ar, now: liveNow, nextStepAt: later, running: nil)
        else { Issue.record("no start"); return }
        #expect(state.counter == "الفرز 1")
        #expect(state.centreName == "مركز الوكرة الصحي")
    }

    @Test(arguments: ["visit_doctor", "visit_pharmacy", "visit_triage_called"])
    func `a later stage or a called ticket with a number starts it too`(name: String) throws {
        let visit = try liveVisit(name)
        guard case .start = LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: later, running: nil)
        else { Issue.record("\(name) did not start"); return }
    }

    // Update

    @Test func `nothing changed and the same stale date gives nothing`() throws {
        let visit = try liveVisit()
        let decision = LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: later,
            running: running(visit, staleDate: later))
        #expect(decision == .none)
    }

    @Test func `any change updates it, with no alert while active`() throws {
        let visit = try liveVisit()
        let decision = LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: later,
            running: running(visit, staleDate: later) { $0.peopleAhead = 4 })
        #expect(decision == .update(LiveTicketRules.state(for: visit, lang: .en), alert: false, staleDate: later))
    }

    @Test func `a new number updates it, as a stage move does`() throws {
        let doctor = try liveVisit("visit_doctor")
        let decision = LiveTicketRules.decide(
            visit: doctor, lang: .en, now: liveNow, nextStepAt: later,
            running: running(try liveVisit(), staleDate: later))
        guard case .update(let state, let alert, _) = decision else {
            Issue.record("no update"); return
        }
        #expect(state.stage == .doctor)
        #expect(state.number == doctor.ticket?.number)
        #expect(!alert)
    }

    @Test func `the move into called alerts, once`() throws {
        let called = try liveVisit(ticket: .called)
        let fromActive = LiveTicketRules.decide(
            visit: called, lang: .en, now: liveNow, nextStepAt: later,
            running: running(try liveVisit(), staleDate: later))
        #expect(fromActive == .update(
            LiveTicketRules.state(for: called, lang: .en), alert: true, staleDate: later))

        // Already called: a change still updates, but does not alert again.
        let again = LiveTicketRules.decide(
            visit: called, lang: .en, now: liveNow, nextStepAt: later,
            running: running(called, staleDate: liveNow) { $0.peopleAhead = 9 })
        guard case .update(_, let alert, _) = again else { Issue.record("no update"); return }
        #expect(!alert)
    }

    @Test(arguments: [TicketState.active, .serving])
    func `no other move alerts`(next: TicketState) throws {
        let previous: TicketState = next == .serving ? .called : .serving
        let decision = LiveTicketRules.decide(
            visit: try liveVisit(ticket: next), lang: .en, now: liveNow, nextStepAt: later,
            running: running(try liveVisit(ticket: previous), staleDate: later))
        guard case .update(_, let alert, _) = decision else { Issue.record("no update"); return }
        #expect(!alert)
    }

    @Test func `moving between stages updates it with no number`() throws {
        let decision = LiveTicketRules.decide(
            visit: try liveVisit(ticket: nil), lang: .en, now: liveNow, nextStepAt: later,
            running: running(try liveVisit(), staleDate: later))
        guard case .update(let state, false, _) = decision else { Issue.record("no update"); return }
        #expect(state.number == nil)
        #expect(LiveTicketRules.phase(state) == .between)
    }

    // The stale date

    @Test func `the stale date is the next planned step while it is ahead`() {
        #expect(LiveTicketRules.staleDate(now: liveNow, nextStepAt: later) == later)
    }

    @Test func `with no plan, or a step already due, it is the short bound`() {
        let bound = liveNow.addingTimeInterval(LiveTicketRules.staleBound)
        #expect(LiveTicketRules.staleDate(now: liveNow, nextStepAt: nil) == bound)
        #expect(LiveTicketRules.staleDate(now: liveNow, nextStepAt: liveNow) == bound)
        #expect(LiveTicketRules.staleDate(now: liveNow, nextStepAt: liveNow.addingTimeInterval(-5)) == bound)
        #expect(LiveTicketRules.staleBound <= 300)
    }

    @Test func `a rebased plan moves the stale date with no other change`() throws {
        let visit = try liveVisit()
        let rebased = liveNow.addingTimeInterval(30)
        let decision = LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: rebased,
            running: running(visit, staleDate: later))
        #expect(decision == .update(
            LiveTicketRules.state(for: visit, lang: .en), alert: false, staleDate: rebased))
    }

    @Test func `with no plan, the stale date is renewed once half the bound has gone`() throws {
        let visit = try liveVisit()
        let fresh = liveNow.addingTimeInterval(LiveTicketRules.staleBound * 0.75)
        #expect(LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: nil,
            running: running(visit, staleDate: fresh)) == .none)
        let old = liveNow.addingTimeInterval(LiveTicketRules.staleBound * 0.25)
        #expect(LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: nil,
            running: running(visit, staleDate: old)) == .update(
                LiveTicketRules.state(for: visit, lang: .en), alert: false,
                staleDate: liveNow.addingTimeInterval(LiveTicketRules.staleBound)))
        #expect(LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: nil,
            running: running(visit, staleDate: nil)) != .none)
    }

    @Test func `the next step at is the first step that has not run`() {
        let plan = demoPlan(performed: 2)
        #expect(LiveTicketRules.nextStepAt(plan) == plan[2].dueAt)
        #expect(LiveTicketRules.nextStepAt(demoPlan(performed: plan.count)) == nil)
        #expect(LiveTicketRules.nextStepAt([]) == nil)
    }

    // Language

    @Test func `a language switch restarts it in the new language`() throws {
        let visit = try liveVisit()
        let decision = LiveTicketRules.decide(
            visit: visit, lang: .en, now: liveNow, nextStepAt: later,
            running: running(visit, lang: .ar, staleDate: later))
        #expect(decision == .restart(LiveTicketRules.state(for: visit, lang: .en), staleDate: later))
        let back = LiveTicketRules.decide(
            visit: visit, lang: .ar, now: liveNow, nextStepAt: later,
            running: running(visit, lang: .en, staleDate: later))
        #expect(back == .restart(LiveTicketRules.state(for: visit, lang: .ar), staleDate: later))
    }

    @Test func `a switch between stages ends it, and the next number starts a new one`() throws {
        let decision = LiveTicketRules.decide(
            visit: try liveVisit(ticket: nil), lang: .en, now: liveNow, nextStepAt: later,
            running: running(try liveVisit(), lang: .ar, staleDate: later))
        #expect(decision == .end(nil, dismissal: .immediate))
    }

    // End

    @Test func `completion ends it with the final state, dismissed after 15 minutes`() throws {
        let completed = try liveVisit("visit_completed")
        let decision = LiveTicketRules.decide(
            visit: completed, lang: .en, now: liveNow, nextStepAt: nil,
            running: running(try liveVisit(), staleDate: later))
        #expect(decision == .end(
            LiveTicketRules.finalState(for: completed, lang: .en),
            dismissal: .after(liveNow.addingTimeInterval(15 * 60))))
        #expect(LiveTicketRules.completeDismissal == 900)
    }

    @Test func `completion with nothing running does nothing`() throws {
        #expect(LiveTicketRules.decide(
            visit: try liveVisit("visit_completed"), lang: .en, now: liveNow, nextStepAt: nil,
            running: nil) == .none)
    }

    @Test(arguments: [
        "visit_emergency", "visit_refill", "visit_expired", "visit_cancelled", "visit_reserved",
        "visit_intake",
    ])
    func `an emergency, or anything that is not a live ticket, ends it at once`(name: String) throws {
        let decision = LiveTicketRules.decide(
            visit: try liveVisit(name), lang: .en, now: liveNow, nextStepAt: later,
            running: running(try liveVisit(), staleDate: later))
        #expect(decision == .end(nil, dismissal: .immediate))
    }
}

/// Fatima's plan at Al Wakra with two simulated tickets ahead, the first `performed` steps run.
func demoPlan(performed: Int = 0, start: Date = liveNow) -> [DemoPlannedStep] {
    let moves: [(DemoStepKind, VisitStage)] = [
        (.queueMoves, .triage), (.queueMoves, .triage), (.callTriage, .triage),
        (.serveTriage, .triage), (.toDoctor, .doctor), (.callDoctor, .doctor),
        (.consult, .pharmacy), (.callPharmacy, .pharmacy), (.dispense, .completed),
    ]
    return moves.enumerated().map { index, move in
        let due = start.addingTimeInterval(Double(index + 1) * 15)
        return DemoPlannedStep(
            kind: move.0, stage: move.1, dueAt: due, performedAt: index < performed ? due : nil)
    }
}
