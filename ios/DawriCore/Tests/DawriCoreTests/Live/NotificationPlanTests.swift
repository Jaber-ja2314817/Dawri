import Foundation
import Testing
@testable import DawriCore

@Suite("Live: NotificationPlan")
struct NotificationPlanTests {
    private func step(_ kind: DemoStepKind, _ stage: VisitStage, in: TimeInterval = 15) -> DemoPlannedStep {
        DemoPlannedStep(kind: kind, stage: stage, dueAt: liveNow.addingTimeInterval(`in`), performedAt: nil)
    }

    @Test func `call steps say you are next, stage moves say the next step is ready`() throws {
        let visit = try liveVisit()
        let plan = demoPlan()
        let notices = NotificationPlan.notices(plan: plan, visit: visit, lang: .en, now: liveNow)
        #expect(notices.map(\.key) == [
            "notify.next", "notify.stage", "notify.next", "notify.stage", "notify.next",
        ])
        // call_triage, to_doctor, call_doctor, the consult that moves to pharmacy, call_pharmacy.
        #expect(notices.map(\.id) == [2, 4, 5, 6, 7].map { "dawri.\(visit.visitId).\($0)" })
        #expect(notices.map(\.fireAt) == [2, 4, 5, 6, 7].map { plan[$0].dueAt })
        #expect(notices.map(\.body) == [
            "You are next", "Your next step is ready", "You are next", "Your next step is ready",
            "You are next",
        ])
        #expect(notices.allSatisfy { $0.title == "Dawri" })
    }

    @Test(arguments: DemoStepKind.allCases)
    func `each kind of step maps to one notice or none`(kind: DemoStepKind) {
        let key = NotificationPlan.key(for: step(kind, kind == .consult ? .pharmacy : .triage))
        switch kind {
        case .callTriage, .callDoctor, .callPharmacy: #expect(key == "notify.next")
        case .toDoctor, .consult: #expect(key == "notify.stage")
        case .queueMoves, .serveTriage, .dispense: #expect(key == nil)
        }
    }

    @Test func `a consult that completes the visit gives nothing, as completion never does`() {
        #expect(NotificationPlan.key(for: step(.consult, .completed)) == nil)
        #expect(NotificationPlan.key(for: step(.dispense, .completed)) == nil)
    }

    @Test func `the queue moving gives nothing`() throws {
        let plan = [step(.queueMoves, .triage), step(.queueMoves, .triage, in: 30)]
        #expect(NotificationPlan.notices(plan: plan, visit: try liveVisit(), lang: .en, now: liveNow).isEmpty)
    }

    @Test func `steps already run, or already past, give nothing`() throws {
        let visit = try liveVisit()
        let performed = demoPlan(performed: 5)
        let ids = NotificationPlan.notices(plan: performed, visit: visit, lang: .en, now: liveNow).map(\.id)
        #expect(ids == [5, 6, 7].map { "dawri.\(visit.visitId).\($0)" })

        // Nothing run, but the clock has reached the fourth step, which is no longer ahead.
        let late = liveNow.addingTimeInterval(4 * 15)
        let lateIds = NotificationPlan.notices(plan: demoPlan(), visit: visit, lang: .en, now: late).map(\.id)
        #expect(lateIds == [4, 5, 6, 7].map { "dawri.\(visit.visitId).\($0)" })
        #expect(NotificationPlan.notices(
            plan: demoPlan(), visit: visit, lang: .en, now: liveNow.addingTimeInterval(3600)).isEmpty)
    }

    @Test func `the ids stay stable when the plan is rebased`() throws {
        let visit = try liveVisit()
        let plan = demoPlan()
        let shifted = plan.map { step in
            var moved = step
            moved.dueAt = step.dueAt.addingTimeInterval(40)
            return moved
        }
        let before = NotificationPlan.notices(plan: plan, visit: visit, lang: .en, now: liveNow)
        let after = NotificationPlan.notices(plan: shifted, visit: visit, lang: .en, now: liveNow)
        #expect(before.map(\.id) == after.map(\.id))
        #expect(zip(before, after).allSatisfy { $1.fireAt == $0.fireAt?.addingTimeInterval(40) })
    }

    @Test func `the notices are in the visit's language, and carry no health detail`() throws {
        let visit = try liveVisit()
        let ar = NotificationPlan.notices(plan: demoPlan(), visit: visit, lang: .ar, now: liveNow)
        #expect(ar.map(\.body) == [
            "أنت التالي", "خطوتك التالية جاهزة", "أنت التالي", "خطوتك التالية جاهزة", "أنت التالي",
        ])
        #expect(ar.allSatisfy { $0.title == "دوري" })
        let words = [
            visit.intake?.chiefComplaintPatientWords ?? "", "حرارة", "fever", "T-014", "Triage",
            "الفرز", "Wakra", "الوكرة",
        ]
        for notice in ar + NotificationPlan.notices(plan: demoPlan(), visit: visit, lang: .en, now: liveNow) {
            for word in words where !word.isEmpty {
                #expect(!notice.title.contains(word) && !notice.body.contains(word))
            }
        }
    }

    @Test(arguments: [
        "visit_reserved", "visit_completed", "visit_emergency", "visit_refill", "visit_expired",
        "visit_cancelled", "visit_intake",
    ])
    func `a visit that is not a live ticket schedules nothing`(name: String) throws {
        #expect(NotificationPlan.notices(
            plan: demoPlan(), visit: try liveVisit(name), lang: .en, now: liveNow).isEmpty)
    }

    @Test func `a call to the counter the patient is already at is left out`() throws {
        let called = try liveVisit(ticket: .called)
        let ids = NotificationPlan.notices(plan: demoPlan(), visit: called, lang: .en, now: liveNow).map(\.id)
        #expect(!ids.contains("dawri.\(called.visitId).2"))
        #expect(ids.contains("dawri.\(called.visitId).5"))
    }

    @Test func `ids carry the visit, so one visit's notices never touch another's`() {
        #expect(NotificationPlan.id(visitId: "V_1", index: 3) == "dawri.V_1.3")
        #expect(NotificationPlan.prefix(visitId: "V_1") == "dawri.V_1.")
        #expect(!NotificationPlan.id(visitId: "V_10", index: 3).hasPrefix(NotificationPlan.prefix(visitId: "V_1")))
    }

    // The engine's own plan

    @Test func `the engine's plan, rebased after a demo next step, keeps its ids and moves its times`() async throws {
        let rig = try LocalRig()
        try await rig.signIn(Said.fatimaQid)
        let id = try await rig.service.arrivedVisit()
        let plan = try await rig.service.demoPlan(visitId: id)
        let visit = try await rig.service.getVisit(visitId: id)
        let first = NotificationPlan.notices(plan: plan, visit: visit, lang: .en, now: rig.clock.now)
        #expect(first.map(\.key) == [
            "notify.next", "notify.stage", "notify.next", "notify.stage", "notify.next",
        ])
        #expect(LiveTicketRules.nextStepAt(plan) == plan[0].dueAt)

        rig.clock.advance(seconds: 2)
        #expect(try await rig.service.demoNextStep(visitId: id) == .moved(.queueMoves))
        let rebased = try await rig.service.demoPlan(visitId: id)
        let moved = try await rig.service.getVisit(visitId: id)
        let second = NotificationPlan.notices(plan: rebased, visit: moved, lang: .en, now: rig.clock.now)
        #expect(second.map(\.id) == first.map(\.id))
        // The next step is now 15 s from the tap, which pulls every later step 13 s earlier.
        #expect(zip(first, second).allSatisfy { $1.fireAt == $0.fireAt?.addingTimeInterval(-13) })
        #expect(LiveTicketRules.nextStepAt(rebased) == rig.clock.now.addingTimeInterval(15))

        // Walk on until the triage call has run: its notice goes, the rest stay.
        while try await rig.service.getVisit(visitId: id).ticket?.state != .called {
            guard case .moved = try await rig.service.demoNextStep(visitId: id) else {
                Issue.record("the demo stopped before the call"); return
            }
        }
        let afterCall = NotificationPlan.notices(
            plan: try await rig.service.demoPlan(visitId: id),
            visit: try await rig.service.getVisit(visitId: id), lang: .en, now: rig.clock.now)
        #expect(afterCall.map(\.id) == Array(first.map(\.id).dropFirst()))
    }

    @Test func `at completion the engine's plan leaves nothing to schedule`() async throws {
        let rig = try LocalRig()
        try await rig.signIn(Said.fatimaQid)
        let id = try await rig.service.arrivedVisit()
        while case .moved = try await rig.service.demoNextStep(visitId: id) {}
        let visit = try await rig.service.getVisit(visitId: id)
        #expect(visit.status == .completed)
        #expect(NotificationPlan.notices(
            plan: try await rig.service.demoPlan(visitId: id), visit: visit, lang: .en,
            now: rig.clock.now).isEmpty)
    }

    // A clinic server: no plan, only what is seen

    @Test func `with no plan, a call seen gives you are next, at once`() throws {
        let notice = NotificationPlan.observed(
            previous: try liveVisit(), next: try liveVisit(ticket: .called), lang: .en)
        #expect(notice?.key == "notify.next")
        #expect(notice?.fireAt == nil)
        #expect(notice?.body == "You are next")
        #expect(notice?.id.hasPrefix("dawri.V_93046b9ef484.") == true)
    }

    @Test func `with no plan, a stage move seen gives the next step is ready`() throws {
        let notice = NotificationPlan.observed(
            previous: try liveVisit(), next: try liveVisit("visit_doctor"), lang: .ar)
        #expect(notice?.key == "notify.stage")
        #expect(notice?.body == "خطوتك التالية جاهزة")
    }

    @Test func `with no plan, nothing else gives a notice`() throws {
        let triage = try liveVisit()
        let called = try liveVisit(ticket: .called)
        #expect(NotificationPlan.observed(previous: nil, next: called, lang: .en) == nil)
        #expect(NotificationPlan.observed(previous: triage, next: triage, lang: .en) == nil)
        #expect(NotificationPlan.observed(previous: called, next: called, lang: .en) == nil)
        #expect(NotificationPlan.observed(previous: called, next: try liveVisit(ticket: .serving), lang: .en) == nil)
        #expect(NotificationPlan.observed(
            previous: try liveVisit("visit_pharmacy"), next: try liveVisit("visit_completed"), lang: .en) == nil)
        #expect(NotificationPlan.observed(
            previous: try liveVisit("visit_reserved"), next: triage, lang: .en) == nil)
    }
}
