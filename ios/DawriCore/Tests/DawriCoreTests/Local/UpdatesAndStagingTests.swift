import Foundation
import Testing
@testable import DawriCore

extension Local {
    @Suite("Local: live updates", .timeLimit(.minutes(1)))
    struct UpdatesTests {
        @Test func `a chat turn on the visit counts as a change`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            var updates = await rig.service.visitUpdates(visitId: visit).makeAsyncIterator()
            #expect(await updates.next() == .open)
            _ = try await rig.service.sendChat(visitId: visit, text: "I have a cough")
            #expect(await updates.next() == .changed)
        }

        @Test func `a change on another visit is not told here`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let mine = try await rig.service.createVisit(patientId: nil).visitId
            let other = try await rig.service.createVisit(patientId: "P004").visitId
            var updates = await rig.service.visitUpdates(visitId: mine).makeAsyncIterator()
            #expect(await updates.next() == .open)
            _ = try await rig.service.sendChat(visitId: other, text: "I have a cough")
            await rig.service.dropStreams(visitId: mine)
            #expect(await updates.next() == .dropped)
            #expect(await updates.next() == nil)
        }

        @Test func `a queue change on a counter reaches whoever waits there`() async throws {
            let rig = try LocalRig(demoClinic: false)
            try await rig.signIn(Said.fatimaQid)
            let first = try await rig.service.arrivedVisit()
            let second = try await rig.service.arrivedVisit(patientId: "P004")
            var updates = await rig.service.visitUpdates(visitId: second).makeAsyncIterator()
            #expect(await updates.next() == .open)
            await rig.service.testing { state, engine in
                _ = try? engine.callNext(&state.clinic, counterId: "C-WAKRA-T1")
            }
            #expect(await updates.next() == .changed)
            #expect(try await rig.service.getVisit(visitId: first).ticket?.state == .called)
        }

        @Test func `a stream for someone else's visit only says dropped`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            try await rig.signIn(Said.raviQid)
            var updates = await rig.service.visitUpdates(visitId: visit).makeAsyncIterator()
            #expect(await updates.next() == .dropped)
            #expect(await updates.next() == nil)
        }

        @Test func `signing out tears the stream down`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            var updates = await rig.service.visitUpdates(visitId: visit).makeAsyncIterator()
            #expect(await updates.next() == .open)
            await rig.service.signOut()
            #expect(await updates.next() == .dropped)
            #expect(await updates.next() == nil)
        }

        @Test func `a reset tells open streams and leaves them open`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            var updates = await rig.service.visitUpdates(visitId: visit).makeAsyncIterator()
            #expect(await updates.next() == .open)
            try await rig.service.resetDemo()
            #expect(await updates.next() == .changed)
        }

        @Test func `the wake reaches an open screen when a reservation lapses`() async throws {
            let box = ClockBox()
            let rig = try LocalRig(sleep: { box.sleep($0) })
            box.clock = rig.clock
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.confirmedVisit()
            var updates = await rig.service.visitUpdates(visitId: visit).makeAsyncIterator()
            #expect(await updates.next() == .open)
            _ = try await rig.service.reserve(visitId: visit, centreId: "C-WAKRA")
            #expect(await updates.next() == .changed)
            #expect(await updates.next() == .changed)
            #expect(try await rig.service.getVisit(visitId: visit).stage == .expired)
        }

        @Test func `a blocked step does not spin the wake`() async throws {
            let box = ClockBox()
            let rig = try LocalRig(sleep: { seconds in
                box.sleep(seconds)
                await Task.yield()
            })
            box.clock = rig.clock
            try await rig.signIn(Said.fatimaQid)
            _ = try await rig.service.arrivedVisit()
            let layla = try await rig.service.arrivedVisit(patientId: "P004")
            var updates = await rig.service.visitUpdates(visitId: layla).makeAsyncIterator()
            #expect(await updates.next() == .open)
            while try await rig.service.getVisit(visitId: layla).stage != .completed {
                _ = await updates.next()
            }
            #expect(box.sleeps < 400)
        }

        @Test func `the stream ends when the service does`() async throws {
            var rig: LocalRig? = try LocalRig()
            try await rig?.signIn(Said.fatimaQid)
            let visit = try #require(try await rig?.service.createVisit(patientId: nil).visitId)
            let stream = try #require(await rig?.service.visitUpdates(visitId: visit))
            var updates = stream.makeAsyncIterator()
            #expect(await updates.next() == .open)
            rig = nil
            #expect(await updates.next() == .dropped)
            #expect(await updates.next() == nil)
        }
    }

    @Suite("Local: staged launches")
    struct StagingTests {
        private static let start = Date(timeIntervalSince1970: 1_794_000_000)

        private static func patient(for stage: VisitStage) -> String {
            stage == .refill ? "P002" : "P001"
        }

        @Test(arguments: VisitStage.allCases)
        func `every stage can be reached`(stage: VisitStage) async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                patientId: Self.patient(for: stage), stage: stage, confirmed: true,
                clock: { Self.start })
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.stage == stage)
            #expect(visit.status.stage == stage)
            #expect(await service.isSignedIn)
            #expect(visit.chat.messages.count >= 1)
            switch stage {
            case .reserved:
                #expect(visit.ticket?.number == nil)
                #expect(visit.ticket?.expiresAt != nil)
            case .triage: #expect(visit.ticket?.number == "T-014")
            case .doctor: #expect(visit.ticket?.number == "D-GP-023")
            case .pharmacy: #expect(visit.ticket?.number == "P-031")
            case .completed: #expect(!visit.medicines.en.isEmpty)
            case .emergency: #expect(visit.emergency != nil)
            case .refill: #expect(visit.refill != nil)
            case .intake: #expect(visit.confirmedByPatient)
            case .expired, .cancelled: #expect(visit.ticket == nil)
            }
        }

        @Test func `intake unconfirmed is the opening line`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(stage: .intake, clock: { Self.start })
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.chat.messages.count == 1)
            #expect(visit.intake == nil)
        }

        @Test(arguments: ["ar", "en"])
        func `a staged chat can be in either language`(language: String) async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .triage, clock: { Self.start }, language: language)
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.chat.language == language)
            #expect(visit.intake?.language.hasPrefix(language) == true)
        }

        @Test func `expired moves the injected clock forward`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(stage: .expired, clock: { Self.start })
            let visit = try await service.getVisit(visitId: visitId)
            let created = try #require(ClinicTime.parse(visit.createdAt))
            let tick = await service.clock()
            #expect(tick.timeIntervalSince(created) >= 45 * 60)
        }

        @Test func `a patient with no medicines cannot be staged at refill`() async throws {
            let refused = await #expect(throws: ClinicError.self) {
                try await LocalClinicService.staged(patientId: "P001", stage: .refill, clock: { Self.start })
            }
            #expect(refused?.code == "not_staged")
        }

        @Test func `staging starts clean whatever the store held`() async throws {
            let store = MemoryClinicStore()
            for _ in 0..<2 {
                let (service, _) = try await LocalClinicService.staged(
                    stage: .triage, clock: { Self.start }, store: store)
                #expect(try await service.listVisits().count == 1)
            }
        }
    }

    @Suite("Local: restored session")
    struct RestoredSessionTests {
        @Test func `a fresh clinic has no session to restore`() throws {
            let rig = try LocalRig()
            #expect(!rig.service.restoredSession)
        }

        @Test func `a saved session is known before anything awaits`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            #expect(!rig.service.restoredSession)
            #expect(rig.rebuilt().restoredSession)
            #expect(await rig.rebuilt().isSignedIn)
        }

        @Test func `signing out leaves nothing to restore`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            await rig.service.signOut()
            #expect(!rig.rebuilt().restoredSession)
        }
    }

    @Suite("Local: staged walks")
    struct StagedWalkTests {
        private static let start = Date(timeIntervalSince1970: 1_794_000_000)

        @Test(arguments: [TicketState.called, .serving])
        func `a ticket state is reached through the demo clinic`(state: TicketState) async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .triage, confirmed: true, clock: { Self.start }, ticketState: state)
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.stage == .triage)
            #expect(visit.ticket?.state == state)
            #expect(visit.ticket?.number == "T-014")
        }

        @Test func `a later stage can be staged at its counter`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .doctor, confirmed: true, clock: { Self.start }, ticketState: .called)
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.stage == .doctor)
            #expect(visit.ticket?.state == .called)
        }

        @Test func `the opening chat is one line`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .intake, clock: { Self.start }, chat: .opening)
            #expect(try await service.getVisit(visitId: visitId).chat.messages.count == 1)
        }

        @Test func `a midway chat is still asking`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .intake, clock: { Self.start }, chat: .midway)
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.chat.messages.count(where: { $0.role == .user }) == 2)
            #expect(visit.intake == nil)
            #expect(!visit.confirmedByPatient)
        }

        @Test func `a summary chat waits for a yes`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .intake, clock: { Self.start }, chat: .summary)
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.intake != nil)
            #expect(!visit.confirmedByPatient)
            #expect(visit.stage == .intake)
        }

        @Test func `the clock ends where it began, with that much of the 45 minutes left`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .reserved, confirmed: true, clock: { Self.start }, expiresIn: 90)
            let visit = try await service.getVisit(visitId: visitId)
            #expect(await service.clock() == Self.start)
            #expect(visit.stage == .reserved)
            let expires = try #require(visit.ticket?.expiresAt.flatMap(ClinicTime.parse))
            #expect(expires == Self.start.addingTimeInterval(90))
        }

        @Test func `a reservation staged with no time left has lapsed`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .reserved, confirmed: true, clock: { Self.start }, expiresIn: -1)
            #expect(try await service.getVisit(visitId: visitId).stage == .expired)
        }

        @Test func `a dependent's visit is booked by the guardian`() async throws {
            let (service, visitId) = try await LocalClinicService.staged(
                stage: .triage, confirmed: true, clock: { Self.start }, dependent: "P004")
            let visit = try await service.getVisit(visitId: visitId)
            #expect(visit.patientId == "P004")
            #expect(visit.bookedBy == "P001")
            #expect(visit.stage == .triage)
            #expect(try await service.getMe().patient.id == "P001")
        }

        @Test func `someone who is not a dependent cannot be staged`() async throws {
            let refused = await #expect(throws: ClinicError.self) {
                try await LocalClinicService.staged(
                    stage: .intake, clock: { Self.start }, dependent: "P003")
            }
            #expect(refused?.status == 403)
        }

        @Test func `a mixed history has every kind of row, with the emergency last`() async throws {
            let (service, visitId) = try await LocalClinicService.stagedHistory(
                patientId: "P002", clock: { Self.start })
            let rows = try await service.listVisits()
            #expect(Set(rows.map(\.stage)) == [.completed, .refill, .expired, .emergency])
            #expect(rows.count == 4)
            #expect(try await service.getVisit(visitId: visitId).stage == .emergency)
        }

        @Test func `a patient with no medicines has no refill row`() async throws {
            let (service, _) = try await LocalClinicService.stagedHistory(
                patientId: "P001", clock: { Self.start })
            let rows = try await service.listVisits()
            #expect(Set(rows.map(\.stage)) == [.completed, .expired, .emergency])
        }
    }

    @Suite("Local: golden coverage")
    struct GoldenCoverageTests {
        private static let tests = "ios/DawriCore/Tests/DawriCoreTests"

        private static func sources() throws -> [String] {
            let root = Repo.root.appending(path: tests)
            let paths = FileManager.default.subpaths(atPath: root.path) ?? []
            return try paths.filter { $0.hasSuffix(".swift") && !$0.hasSuffix("UpdatesAndStagingTests.swift") }
                .map { try Repo.text("\(tests)/\($0)") }
        }

        @Test(arguments: GoldenFolder.allCases)
        func `every file in every manifest is read by a test`(folder: GoldenFolder) throws {
            let sources = try Self.sources()
            #expect(sources.count > 10)
            let names = try Golden.manifest(folder).files.keys.sorted()
            #expect(!names.isEmpty)
            for file in names {
                let name = file.replacingOccurrences(of: ".json", with: "")
                let loaded = sources.contains {
                    $0.contains(".\(folder.rawValue), \"\(name)\"")
                }
                #expect(loaded, "No test loads \(folder.rawValue)/\(file)")
            }
        }
    }
}
