import Foundation
import Synchronization
import Testing
@testable import DawriCore

extension Local {
    @Suite("Local: demo clinic")
    struct DemoClinicTests {
        private static let triageOn: [DemoStepKind] = [
            .callTriage, .serveTriage, .toDoctor, .callDoctor, .consult, .callPharmacy, .dispense,
        ]

        /// A clinic where these drugs are the demo prescription.
        private func rig(demoDrugs: [String]) throws -> LocalRig {
            let clock = try TestClock(journeyStart)
            var engine = QueueEngine(clock: { clock.now })  // The rig counts its own ids from one.
            var state = try LocalState.fresh(engine: &engine)
            for index in state.clinic.drugs.indices {
                state.clinic.drugs[index].demoDefault =
                    demoDrugs.contains(state.clinic.drugs[index].id) ? 1 : 0
            }
            return try LocalRig(store: try MemoryClinicStore(state: state))
        }

        private func step(_ rig: LocalRig, _ visit: String, until stage: VisitStage) async throws {
            while try await rig.service.getVisit(visitId: visit).stage != stage {
                guard case .moved = try await rig.service.demoNextStep(visitId: visit) else {
                    Issue.record("The demo stopped short of \(stage)")
                    return
                }
            }
        }

        @Test func `no plan exists until the patient arrives`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.confirmedVisit()
            _ = try await rig.service.reserve(visitId: visit, centreId: "C-WAKRA")
            #expect(try await rig.service.demoPlan(visitId: visit).isEmpty)
            #expect(try await rig.service.demoNextStep(visitId: visit) == .finished)
            rig.clock.advance(seconds: 120)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .reserved)
        }

        @Test func `the plan is known ahead, 15 seconds apart, with the stage each step reaches`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            let plan = try await rig.service.demoPlan(visitId: visit)
            #expect(plan.map(\.kind) == [.queueMoves, .queueMoves, .queueMoves] + Self.triageOn)
            #expect(plan.map(\.stage) == [
                .triage, .triage, .triage, .triage, .triage, .doctor, .doctor, .pharmacy, .pharmacy,
                .completed,
            ])
            let start = rig.clock.now
            for (index, step) in plan.enumerated() {
                #expect(step.dueAt.timeIntervalSince(start) == Double(index + 1) * 15)
                #expect(step.performedAt == nil)
            }
        }

        @Test func `the next step runs now and later times move with it`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 2)
            #expect(try await rig.service.demoNextStep(visitId: visit) == .moved(.queueMoves))
            let plan = try await rig.service.demoPlan(visitId: visit)
            let now = rig.clock.now
            #expect(plan[0].performedAt == now)
            #expect(plan[1].performedAt == nil)
            for (offset, step) in plan.dropFirst().enumerated() {
                #expect(step.dueAt.timeIntervalSince(now) == Double(offset + 1) * 15)
            }
            #expect(try await rig.service.getVisit(visitId: visit).ticket?.peopleAhead == 2)
        }

        @Test func `the control walks to the end and then says so`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            var kinds: [DemoStepKind] = []
            while case .moved(let kind) = try await rig.service.demoNextStep(visitId: visit) {
                kinds.append(kind)
            }
            #expect(kinds == [.queueMoves, .queueMoves, .queueMoves] + Self.triageOn)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .completed)
            #expect(try await rig.service.demoNextStep(visitId: visit) == .finished)
        }

        @Test func `every row says demo and nothing poses as staff`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 600)
            _ = try await rig.service.getVisit(visitId: visit)
            let rows = await rig.service.testing { state, _ in
                state.clinic.events.filter { $0.visitId == visit }
            }
            let actors = rows.compactMap { row -> String? in
                guard case .object(let fields) = row.payload, case .string(let id)? = fields["staff_id"]
                else { return nil }
                return id
            }
            #expect(actors.count >= 12)
            #expect(actors.allSatisfy { $0.hasPrefix("demo:") })
            #expect(rows.contains { $0.type == "consult.done" })
            #expect(rows.contains { $0.type == "dispensed" })
        }

        @Test func `moves go through the engine, with its events`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 600)
            _ = try await rig.service.getVisit(visitId: visit)
            let types = await rig.service.testing { state, _ in
                state.clinic.events.filter { $0.visitId == visit }.map(\.type)
            }
            #expect(types.filter { $0 == "ticket.called" }.count == 3)
            #expect(types.filter { $0 == "ticket.done" }.count == 3)
            #expect(types.filter { $0 == "ticket.activated" }.count == 3)
            let finished = await rig.service.testing { state, _ in
                state.clinic.events.filter {
                    $0.type == "ticket.simulated_done"
                        && $0.payload.object?["counter_id"]?.string == "C-WAKRA-T1"
                }.count
            }
            #expect(finished == 3)
        }

        @Test func `DR-AMOX forced in reaches everyone but Fatima`() async throws {
            let rig = try rig(demoDrugs: ["DR-PARA", "DR-DEXT", "DR-AMOX"])
            try await rig.signIn(Said.fatimaQid)
            let fatima = try await rig.service.arrivedVisit()
            let layla = try await rig.service.arrivedVisit(patientId: "P004")
            try await rig.signIn(Said.ahmedQid)
            let ahmed = try await rig.service.arrivedVisit(centre: "C-RAYYAN")
            rig.clock.advance(seconds: 1200)
            _ = await rig.service.health()

            func drugs(_ visit: String) async -> [String] {
                await rig.service.testing { state, _ in
                    state.clinic.prescriptions.filter { $0.visitId == visit }.map(\.drug)
                }
            }
            #expect(await drugs(fatima) == ["DR-DEXT", "DR-PARA"])
            #expect(await drugs(layla) == ["DR-AMOX", "DR-DEXT", "DR-PARA"])
            #expect(await drugs(ahmed) == ["DR-AMOX", "DR-DEXT", "DR-PARA"])
            #expect(await rig.service.events("prescription.allergy_override").isEmpty)
            let statuses = await rig.service.testing { state, _ in
                state.clinic.visits.map(\.status)
            }
            #expect(statuses == [.completed, .completed, .completed])
        }

        @Test func `only a penicillin as the demo list leaves Fatima with no pharmacy`() async throws {
            let rig = try rig(demoDrugs: ["DR-AMOX"])
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            let plan = try await rig.service.demoPlan(visitId: visit)
            #expect(plan.last?.kind == .consult)
            #expect(plan.last?.stage == .completed)
            rig.clock.advance(seconds: 600)
            let done = try await rig.service.getVisit(visitId: visit)
            #expect(done.stage == .completed)
            #expect(done.medicines.en.isEmpty)
            #expect(done.ticket?.number == "D-GP-023")
            let pharmacy = await rig.service.testing { state, _ in
                state.clinic.tickets.contains { $0.counterId == "C-WAKRA-P1" }
            }
            #expect(!pharmacy)
        }

        @Test func `an empty demo list finishes at the doctor even when the plan expected a pharmacy`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            await rig.service.testing { state, _ in
                for index in state.clinic.drugs.indices { state.clinic.drugs[index].demoDefault = 0 }
            }
            rig.clock.advance(seconds: 600)
            let done = try await rig.service.getVisit(visitId: visit)
            #expect(done.stage == .completed)
            #expect(try await rig.service.demoNextStep(visitId: visit) == .finished)
        }

        @Test(arguments: [("P001", "P004"), ("P004", "P001")])
        func `two real visits at one counter never skip each other`(first: String, second: String) async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let one = try await rig.service.arrivedVisit(patientId: first)
            let two = try await rig.service.arrivedVisit(patientId: second)
            rig.clock.advance(seconds: 15 * 40)
            #expect(try await rig.service.getVisit(visitId: one).stage == .completed)
            #expect(try await rig.service.getVisit(visitId: two).stage == .completed)

            let rows = await rig.service.testing { state, _ in
                state.clinic.events.filter { $0.type == "ticket.called" || $0.type == "ticket.done" }
            }
            func moment(_ type: String, _ visit: String, _ counter: String) throws -> Int {
                try #require(rows.firstIndex {
                    $0.type == type && $0.visitId == visit
                        && $0.payload.object?["counter_id"]?.string == counter
                })
            }
            for counter in ["C-WAKRA-T1", "C-WAKRA-P1"] {
                #expect(try moment("ticket.done", one, counter) < moment("ticket.called", two, counter), "\(counter)")
            }
            let numbers = await rig.service.testing { state, _ in
                [one, two].map { visit in
                    state.clinic.tickets.filter { $0.visitId == visit }.compactMap(\.number)
                }
            }
            #expect(numbers[0].first == "T-014")
            #expect(numbers[1].first == "T-015")
            #expect(numbers[0].last == "P-031")
            #expect(numbers[1].last == "P-032")
        }

        @Test func `a step behind a real patient waits and retries`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let fatima = try await rig.service.arrivedVisit()
            let layla = try await rig.service.arrivedVisit(patientId: "P004")
            for _ in 0..<3 {
                #expect(try await rig.service.demoNextStep(visitId: layla) == .moved(.queueMoves))
            }
            #expect(try await rig.service.demoNextStep(visitId: layla) == .waiting)
            #expect(try await rig.service.getVisit(visitId: layla).ticket?.state == .active)
            #expect(try await rig.service.getVisit(visitId: layla).ticket?.peopleAhead == 1)

            // Fatima's own moves were used up by the simulated tickets already gone.
            #expect(try await rig.service.demoNextStep(visitId: fatima) == .moved(.callTriage))
            #expect(try await rig.service.demoNextStep(visitId: layla) == .waiting)
            #expect(try await rig.service.demoNextStep(visitId: fatima) == .moved(.serveTriage))
            #expect(try await rig.service.demoNextStep(visitId: layla) == .waiting)
            #expect(try await rig.service.demoNextStep(visitId: fatima) == .moved(.toDoctor))
            #expect(try await rig.service.demoNextStep(visitId: layla) == .moved(.callTriage))
        }

        @Test func `a waiting step moves its later times`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let fatima = try await rig.service.arrivedVisit()
            let layla = try await rig.service.arrivedVisit(patientId: "P004")
            for _ in 0..<3 { try await rig.service.demoNextStep(visitId: layla) }
            rig.clock.advance(seconds: 1)
            #expect(try await rig.service.demoNextStep(visitId: layla) == .waiting)
            let plan = try await rig.service.demoPlan(visitId: layla)
            #expect(plan[3].dueAt.timeIntervalSince(rig.clock.now) == 15)
            #expect(plan[4].dueAt.timeIntervalSince(plan[3].dueAt) == 15)
            #expect(try await rig.service.getVisit(visitId: fatima).ticket?.number == "T-014")
        }

        @Test(arguments: [VisitStage.triage, .doctor, .pharmacy])
        func `an emergency stops the run for good`(stage: VisitStage) async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            try await step(rig, visit, until: stage)
            let before = await rig.service.events("demo.step").count

            let reply = try await rig.service.sendChat(visitId: visit, text: "chest pain")
            #expect(reply.emergency)
            let seen = try await rig.service.getVisit(visitId: visit)
            #expect(seen.stage == .emergency)
            #expect(seen.ticket == nil)

            rig.clock.advance(seconds: 3600)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .emergency)
            #expect(try await rig.service.demoNextStep(visitId: visit) == .finished)
            #expect(await rig.service.events("demo.step").count == before)
            let status = await rig.service.testing { state, _ in state.demoRuns[visit]?.status }
            #expect(status == .cancelled)
            let medicines = try await rig.service.getVisit(visitId: visit).medicines
            #expect(stage != .pharmacy || !medicines.en.isEmpty, "What was prescribed stays on record")
        }

        @Test func `a guardian's run goes on when a dependent is stopped`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let fatima = try await rig.service.arrivedVisit()
            let layla = try await rig.service.arrivedVisit(patientId: "P004")
            _ = try await rig.service.sendChat(visitId: layla, text: "chest pain")
            rig.clock.advance(seconds: 600)
            #expect(try await rig.service.getVisit(visitId: layla).stage == .emergency)
            #expect(try await rig.service.getVisit(visitId: fatima).stage == .completed)
        }

        @Test func `a patient with priority still goes through the queue rules`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let fatima = try await rig.service.arrivedVisit()
            let elder = try await rig.service.arrivedVisit(patientId: "P005")
            let plan = try await rig.service.demoPlan(visitId: elder)
            #expect(plan.first?.kind == .callTriage, "P005 is over the age rule, so nothing is ahead")
            rig.clock.advance(seconds: 15)
            let seen = try await rig.service.getVisit(visitId: elder)
            #expect(seen.ticket?.state == .called)
            #expect(try await rig.service.getVisit(visitId: fatima).ticket?.number == "T-014")
        }

        @Test func `reset reseeds and keeps the session`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            try await rig.service.resetDemo()
            #expect(await rig.service.isSignedIn)
            #expect(try await rig.service.listVisits().isEmpty)
            let gone = await #expect(throws: ClinicError.self) {
                try await rig.service.getVisit(visitId: visit)
            }
            #expect(gone?.code == "visit_not_found")
            #expect(await rig.service.events("demo.reset").count == 1)
            let again = try await rig.service.arrivedVisit()
            #expect(try await rig.service.getVisit(visitId: again).ticket?.number == "T-014")
        }

        @Test(.timeLimit(.minutes(1)))
        func `a stream sees the wake drive the visit to the end`() async throws {
            let box = ClockBox()
            let rig = try LocalRig(sleep: { seconds in
                box.sleep(seconds)
                await Task.yield()
            })
            box.clock = rig.clock
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            var updates = await rig.service.visitUpdates(visitId: visit).makeAsyncIterator()
            #expect(await updates.next() == .open)
            var changes = 0
            while try await rig.service.getVisit(visitId: visit).stage != .completed {
                #expect(await updates.next() == .changed)
                changes += 1
            }
            #expect(changes >= 5)
        }
    }
}

/// Lets a sleep closure reach a clock made after it, and counts how often it ran.
final class ClockBox: Sendable {
    private struct Inside {
        var clock: TestClock?
        var sleeps = 0
    }

    private let inside = Mutex(Inside())

    var clock: TestClock? {
        get { inside.withLock { $0.clock } }
        set { inside.withLock { $0.clock = newValue } }
    }

    var sleeps: Int { inside.withLock { $0.sleeps } }

    func sleep(_ seconds: TimeInterval) {
        inside.withLock {
            $0.sleeps += 1
            $0.clock?.advance(seconds: seconds)
        }
    }
}
