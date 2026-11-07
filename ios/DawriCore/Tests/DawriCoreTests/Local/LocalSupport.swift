import Foundation
import Testing
@testable import DawriCore

/// The namespace of every suite here, so `swift test --filter Local` finds them all.
enum Local {}

/// `common.START`: noon in Doha on 7 November.
let journeyStart = "2026-11-07T09:00:00.000000+00:00"

/// Serves one state and keeps nothing, for replays that make thousands of services.
struct FixedClinicStore: ClinicStore {
    let state: LocalState
    func load() -> LocalState? { state }
    func save(_ state: LocalState) throws {}
}

/// A service on a test clock with a real encoded store, and what a test needs to rebuild it.
struct LocalRig {
    let clock: TestClock
    let ids: CountingIds
    let store: any ClinicStore
    let service: LocalClinicService

    init(
        start: String = journeyStart, store: any ClinicStore = MemoryClinicStore(), demoClinic: Bool = true,
        sleep: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) throws {
        let clock = try TestClock(start)
        let ids = CountingIds()
        self.clock = clock
        self.ids = ids
        self.store = store
        service = Self.make(clock, ids, store, demoClinic: demoClinic, sleep: sleep)
    }

    private static func make(
        _ clock: TestClock, _ ids: CountingIds, _ store: any ClinicStore, demoClinic: Bool,
        sleep: (@Sendable (TimeInterval) async throws -> Void)?
    ) -> LocalClinicService {
        if let sleep {
            return LocalClinicService(
                clock: { clock.now }, newId: { ids.next($0) }, store: store, sleep: sleep,
                demoClinic: demoClinic)
        }
        return LocalClinicService(
            clock: { clock.now }, newId: { ids.next($0) }, store: store, demoClinic: demoClinic)
    }

    /// What a killed app comes back to: the same store, a new service, nothing else.
    func rebuilt() -> LocalClinicService {
        Self.make(clock, ids, store, demoClinic: true, sleep: nil)
    }

    func signIn(_ qid: String, on service: LocalClinicService? = nil) async throws {
        _ = try await (service ?? self.service).authVerify(qid: qid, otp: "0000")
    }
}

/// The demo patients' own sentences, from ios/Tools/export/journeys.py.
enum Said {
    static let fatimaQid = "DEMO-10001"
    static let ahmedQid = "DEMO-10002"
    static let raviQid = "DEMO-10003"

    static let fatima = [
        "ar": ["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"],
        "en": ["I have a fever and cough for three days", "6", "panadol", "no"],
    ]
    static let ahmed = ["ar": "أبي حبوب الضغط المعتادة", "en": "I need my usual blood pressure tablets."]
    static let ravi = ["ar": "عندي ألم في الصدر ينتشر إلى ذراعي", "en": "Chest pain going to my left arm."]
}

extension LocalClinicService {
    /// A finished, confirmed chat for this patient.
    func confirmedVisit(language: String = "en", patientId: String? = nil) async throws -> String {
        let visit = try createVisit(patientId: patientId).visitId
        for line in try #require(Said.fatima[language]) {
            _ = try sendChat(visitId: visit, text: line)
        }
        _ = try confirmIntake(visitId: visit, service: nil)
        return visit
    }

    func arrivedVisit(
        language: String = "en", patientId: String? = nil, centre: String = "C-WAKRA"
    ) async throws -> String {
        let visit = try await confirmedVisit(language: language, patientId: patientId)
        _ = try reserve(visitId: visit, centreId: centre)
        _ = try arrive(visitId: visit, body: .button)
        return visit
    }

    /// Events of one type on one visit, oldest first.
    func events(_ type: String, visitId: String? = nil) -> [EventRecord] {
        state.clinic.events.filter { $0.type == type && (visitId == nil || $0.visitId == visitId) }
    }
}
