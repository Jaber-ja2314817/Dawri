import Foundation
import Synchronization
import Testing
@testable import DawriCore

/// On this phone. The demo clinic stands in for staff, and the injected clock for waiting.
final class LocalHarness: ContractHarness {
    private let clocks = Mutex<[ObjectIdentifier: TestClock]>([:])

    var testDescription: String { "on this phone" }

    private func local(_ service: any ClinicService) throws -> LocalClinicService {
        try #require(service as? LocalClinicService)
    }

    func makeService() async throws -> any ClinicService {
        let clock = try TestClock("2026-11-07T09:00:00.000000+00:00")
        let service = LocalClinicService(clock: { clock.now }, store: MemoryClinicStore())
        clocks.withLock { $0[ObjectIdentifier(service)] = clock }
        return service
    }

    func moveToNextStage(_ service: any ClinicService, visitId: String) async throws {
        let local = try local(service)
        let start = try await local.getVisit(visitId: visitId).stage
        while try await local.getVisit(visitId: visitId).stage == start {
            let outcome = try await local.demoNextStep(visitId: visitId)
            guard case .moved = outcome else {
                Issue.record("The demo stopped at \(start) with \(outcome)")
                return
            }
        }
    }

    func dropUpdates(_ service: any ClinicService, visitId: String) async throws {
        try await local(service).dropStreams(visitId: visitId)
    }

    func expireReservation(_ service: any ClinicService, visitId: String) async throws {
        let local = try local(service)
        let clock = try #require(clocks.withLock { $0[ObjectIdentifier(local)] })
        clock.advance(seconds: 46 * 60)
    }
}
