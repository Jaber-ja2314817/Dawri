import Foundation
import Testing
@testable import DawriCore

/// What the contract suite needs and `ClinicService` cannot give it, because on a real clinic
/// staff do these things. A second back end adds a harness here and reuses every test.
protocol ContractHarness: Sendable, CustomTestStringConvertible {
    /// A fresh demo, signed out, that shares nothing with any other service.
    func makeService() async throws -> any ClinicService
    /// Moves a visit that has arrived on to its next stage.
    func moveToNextStage(_ service: any ClinicService, visitId: String) async throws
    /// Ends the visit's live updates, as a lost connection would.
    func dropUpdates(_ service: any ClinicService, visitId: String) async throws
    /// Lets the 45 minutes of a reservation run out.
    func expireReservation(_ service: any ClinicService, visitId: String) async throws
}

let contractHarnesses: [any ContractHarness] = [LocalHarness()]
