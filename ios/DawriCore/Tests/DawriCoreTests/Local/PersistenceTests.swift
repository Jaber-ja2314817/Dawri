import Foundation
import Synchronization
import Testing
@testable import DawriCore

private func temporaryFile() -> URL {
    FileManager.default.temporaryDirectory
        .appending(path: "dawri-\(UUID().uuidString)/nested/clinic-state.json")
}

/// Counts saves, and can refuse them, as a full disk would.
private final class WatchedStore: ClinicStore {
    let inner = MemoryClinicStore()
    private let saves = Mutex(0)
    let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var count: Int { saves.withLock { $0 } }

    func load() -> LocalState? { inner.load() }

    func save(_ state: LocalState) throws {
        saves.withLock { $0 += 1 }
        if failing { throw CocoaError(.fileWriteOutOfSpace) }
        try inner.save(state)
    }
}

extension Local {
    @Suite("Local: persistence")
    struct PersistenceTests {
        @Test func `the default file is under Application Support`() {
            #expect(FileClinicStore.defaultURL.path.hasSuffix("Application Support/Dawri/clinic-state.json"))
        }

        @Test func `a file store creates its folder and leaves one file`() async throws {
            let url = temporaryFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
            let store = FileClinicStore(url: url)
            #expect(store.load() == nil)
            let rig = try LocalRig(store: store)
            try await rig.signIn(Said.fatimaQid)
            let names = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            #expect(names == ["clinic-state.json"])
            #expect(store.load()?.subject?.id == "P001")
        }

        @Test func `state survives the whole round trip`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            _ = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 30)
            _ = try await rig.service.listVisits()
            let live = await rig.service.state
            let decoded = try #require(LocalState.decoded(try live.encoded()))
            #expect(decoded == live)
            #expect(rig.store.load() == live)
        }

        @Test func `every mutation saves and a read does not`() async throws {
            let store = WatchedStore()
            let rig = try LocalRig(store: store)
            let start = store.count
            #expect(start == 1, "The seed is saved")
            try await rig.signIn(Said.fatimaQid)
            #expect(store.count == start + 1)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            #expect(store.count == start + 2)
            _ = try await rig.service.sendChat(visitId: visit, text: "I have a cough")
            #expect(store.count == start + 3)
            _ = try await rig.service.getVisit(visitId: visit)
            _ = try await rig.service.listVisits()
            #expect(store.count == start + 3)
        }

        @Test func `a refused message that was kept is saved too`() async throws {
            let store = WatchedStore()
            let rig = try LocalRig(store: store)
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.confirmedVisit()
            _ = try await rig.service.reserve(visitId: visit, centreId: "C-WAKRA")
            let refused = await #expect(throws: ClinicError.self) {
                try await rig.service.sendChat(visitId: visit, text: "pain")
            }
            #expect(refused?.code == "visit_not_in_intake")
            #expect(store.load()?.chats[visit]?.messages.last?.content == "pain")
        }

        @Test func `a store that cannot write leaves the clinic working`() async throws {
            let rig = try LocalRig(store: WatchedStore(failing: true))
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            #expect(try await rig.service.getVisit(visitId: visit).ticket?.number == "T-014")
        }

        @Test(arguments: ["en", "ar"])
        func `a rebuilt service carries on the chat`(language: String) async throws {
            let lines = try #require(Said.fatima[language])
            let whole = try LocalRig()
            try await whole.signIn(Said.fatimaQid)
            let visit = try await whole.service.createVisit(patientId: nil).visitId
            var replies: [String] = []
            for line in lines {
                replies.append(try await whole.service.sendChat(visitId: visit, text: line).reply)
            }

            let broken = try LocalRig()
            try await broken.signIn(Said.fatimaQid)
            let same = try await broken.service.createVisit(patientId: nil).visitId
            var service = broken.service
            var found: [String] = []
            for line in lines {
                found.append(try await service.sendChat(visitId: same, text: line).reply)
                service = broken.rebuilt()
            }
            #expect(found == replies)
            #expect(await service.isSignedIn)
            let answer = try await service.confirmIntake(visitId: same, service: nil)
            #expect(answer.service == .gp)
        }

        @Test func `a rebuilt service keeps the ticket and the emergency`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.raviQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            _ = try await rig.service.sendChat(visitId: visit, text: try #require(Said.ravi["en"]))
            let back = rig.rebuilt()
            #expect(try await back.getVisit(visitId: visit).stage == .emergency)
            await #expect(throws: ClinicError.self) { try await back.createVisit(patientId: nil) }
        }

        @Test func `steps that fell due while the app was gone run on return, at their own times`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            let plan = try await rig.service.demoPlan(visitId: visit)
            try await rig.service.demoNextStep(visitId: visit)
            let later = try await rig.service.demoPlan(visitId: visit)

            rig.clock.advance(seconds: 3600)
            let back = rig.rebuilt()
            let done = try await back.getVisit(visitId: visit)
            #expect(done.stage == .completed)
            #expect(done.ticket?.number == "P-031")
            #expect(done.medicines.en.map(\.drug) == ["DR-DEXT", "DR-PARA"])
            let last = try #require(later.last)
            #expect(done.completedAt == ClinicTime.iso(last.dueAt))
            #expect(plan.count == later.count)
            #expect(try await back.demoPlan(visitId: visit).allSatisfy { $0.performedAt != nil })
        }

        @Test func `a run part done carries on and is not repeated`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 15 * 5)
            let first = rig.rebuilt()
            #expect(try await first.getVisit(visitId: visit).ticket?.state == .serving)
            rig.clock.advance(seconds: 15)
            let second = rig.rebuilt()
            let seen = try await second.getVisit(visitId: visit)
            #expect(seen.stage == .doctor)
            #expect(seen.ticket?.number == "D-GP-023")
            #expect(await second.events("ticket.called", visitId: visit).count == 1)
        }

        @Test func `an emergency before the rebuild keeps the run stopped`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            _ = try await rig.service.sendChat(visitId: visit, text: "chest pain")
            rig.clock.advance(seconds: 3600)
            let back = rig.rebuilt()
            #expect(try await back.getVisit(visitId: visit).stage == .emergency)
            #expect(await back.events("demo.step").isEmpty)
        }

        @Test(arguments: [
            Data("this is not json".utf8), Data(), Data(#"{"schemaVersion":1}"#.utf8),
            Data(#"[1,2,3]"#.utf8),
        ])
        func `a corrupt file reseeds`(bytes: Data) async throws {
            let url = temporaryFile()
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent().deletingLastPathComponent()) }
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: url)
            let store = FileClinicStore(url: url)
            let rig = try LocalRig(store: store)
            #expect(await !rig.service.isSignedIn)
            #expect(await rig.service.demoPatients().count >= 3)
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            #expect(try await rig.service.getVisit(visitId: visit).ticket?.number == "T-014")
            #expect(store.load() != nil, "The damaged file was replaced")
        }

        @Test func `a file from another schema reseeds`() async throws {
            let clock = try TestClock(journeyStart)
            var engine = makeEngine(clock)
            var state = try LocalState.fresh(engine: &engine, subject: SessionSubject(kind: .patient, id: "P001"))
            state.schemaVersion = LocalState.currentSchema + 1
            let store = try MemoryClinicStore(state: state)
            #expect(store.load() == nil)
            let rig = try LocalRig(store: store)
            #expect(await !rig.service.isSignedIn)
        }
    }

    @Suite("Local: a new Doha day")
    struct DayRolloverTests {
        /// 23:50 in Doha, ten minutes before the day turns.
        private static let lateEvening = "2026-11-07T20:50:00.000000+00:00"

        /// The protected centre's simulated tickets, which only a new day replaces.
        private func wakra(_ rig: LocalRig) async -> [TicketRecord] {
            await rig.service.testing { state, _ in
                state.clinic.tickets.filter { $0.simulated && $0.centreId == "C-WAKRA" }
            }
        }

        @Test func `the day turns at Doha's midnight and not before`() async throws {
            let rig = try LocalRig(start: Self.lateEvening)
            rig.clock.advance(seconds: 599)
            _ = await rig.service.health()
            #expect(await rig.service.state.queueDay == "2026-11-07")
            rig.clock.advance(seconds: 1)
            _ = await rig.service.health()
            #expect(await rig.service.state.queueDay == "2026-11-08")
        }

        @Test func `a new day reseeds the queue and keeps the patient's history`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 600)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .completed)
            let before = await rig.service.state
            #expect(before.clinic.events.count > 0)

            rig.clock.advance(seconds: 86_400)
            let rows = try await rig.service.listVisits()
            let after = await rig.service.state
            #expect(rows.map(\.visitId) == [visit])
            #expect(rows.first?.stage == .completed)
            #expect(after.queueDay == "2026-11-08")
            #expect(after.chats[visit] == before.chats[visit])
            #expect(after.clinic.prescriptions == before.clinic.prescriptions)
            #expect(after.clinic.tickets.filter { !$0.simulated } == before.clinic.tickets.filter { !$0.simulated })
            #expect(after.clinic.events.starts(with: before.clinic.events))
            #expect(Set(after.clinic.sequences.map(\.day)) == ["2026-11-08"])

            let simulated = after.clinic.tickets.filter(\.simulated)
            let seeded = ClinicData.bundled.constants.simulatedTickets.reduce(0) { $0 + $1.value }
            #expect(simulated.count == seeded)
            #expect(simulated.allSatisfy { $0.state == .active && $0.day == "2026-11-08" })

            let seen = try await rig.service.getVisit(visitId: visit)
            #expect(seen.ticket?.number == "P-031")
            #expect(seen.medicines.en.count == 2)

            let tomorrow = try await rig.service.arrivedVisit()
            #expect(try await rig.service.getVisit(visitId: tomorrow).ticket?.number == "T-014")
        }

        @Test func `the day waits while a real ticket is live`() async throws {
            let rig = try LocalRig(start: Self.lateEvening, demoClinic: false)
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            let simulated = await wakra(rig)

            rig.clock.advance(seconds: 3600)
            #expect(try await rig.service.getVisit(visitId: visit).ticket?.number == "T-014")
            #expect(await rig.service.state.queueDay == "2026-11-07")
            #expect(await wakra(rig) == simulated)

            await rig.service.testing { state, engine in
                let ticket = engine.liveTicket(state.clinic, visitId: visit)
                if let ticket { _ = try? engine.escalate(&state.clinic, ticketId: ticket.id, reason: "test") }
            }
            _ = await rig.service.health()
            #expect(await rig.service.state.queueDay == "2026-11-08")
            #expect(await wakra(rig) != simulated)
        }

        @Test func `a reservation running out lets the day turn`() async throws {
            let rig = try LocalRig(start: Self.lateEvening)
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.confirmedVisit()
            _ = try await rig.service.reserve(visitId: visit, centreId: "C-WAKRA")
            rig.clock.advance(seconds: 20 * 60)
            _ = await rig.service.health()
            #expect(await rig.service.state.queueDay == "2026-11-07", "45 minutes have not passed")
            rig.clock.advance(seconds: 30 * 60)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .expired)
            #expect(await rig.service.state.queueDay == "2026-11-08")
        }

        @Test func `a run crossing midnight finishes before the queue turns over`() async throws {
            let rig = try LocalRig(start: "2026-11-07T20:59:00.000000+00:00")
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            rig.clock.advance(seconds: 15 * 20)
            let done = try await rig.service.getVisit(visitId: visit)
            #expect(done.stage == .completed)
            #expect(await rig.service.state.queueDay == "2026-11-08")
        }

        @Test func `emergency_today stays keyed by the day`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.raviQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            _ = try await rig.service.sendChat(visitId: visit, text: try #require(Said.ravi["en"]))
            let today = await #expect(throws: ClinicError.self) {
                try await rig.service.createVisit(patientId: nil)
            }
            #expect(today?.code == "emergency_today")

            rig.clock.advance(seconds: 86_400)
            let next = try await rig.service.createVisit(patientId: nil)
            #expect(next.status == .intake)
            #expect(try await rig.service.listVisits().count == 2)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .emergency)
        }
    }

    @Suite("Local: the simulated load")
    struct SimulatedLoadTests {
        private func waiting(_ rig: LocalRig, _ counter: String) async -> Int {
            await rig.service.testing { state, _ in
                state.clinic.tickets.count {
                    $0.counterId == counter && $0.simulated && $0.state == .active
                }
            }
        }

        @Test func `ticks follow elapsed time and leave the protected centre alone`() async throws {
            let rig = try LocalRig()
            let wakra = await waiting(rig, "C-WAKRA-T1")
            let airport = await waiting(rig, "C-AIRPORT-T1")
            rig.clock.advance(seconds: 59)
            _ = await rig.service.health()
            #expect(await waiting(rig, "C-AIRPORT-T1") == airport)
            rig.clock.advance(seconds: 1)
            _ = await rig.service.health()
            #expect(await waiting(rig, "C-AIRPORT-T1") == airport - 1)
            #expect(await waiting(rig, "C-WAKRA-T1") == wakra)
        }

        @Test func `a long gap runs a few ticks and then counts the rest as done`() async throws {
            let rig = try LocalRig()
            let serial = await rig.service.state.clinic.events.count
            rig.clock.advance(seconds: 60 * 500 + 7)
            _ = await rig.service.health()
            let state = await rig.service.state
            #expect(state.clinic.events.count - serial < 200)
            #expect(state.lastTickMicros == ClinicTime.microseconds(of: rig.clock.now) - 7_000_000)
        }

        @Test func `the load never moves T-014`() async throws {
            let rig = try LocalRig()
            rig.clock.advance(seconds: 3000)
            _ = await rig.service.health()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            #expect(try await rig.service.getVisit(visitId: visit).ticket?.number == "T-014")
        }
    }
}
