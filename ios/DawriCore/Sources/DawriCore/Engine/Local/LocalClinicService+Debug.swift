#if DEBUG
import Foundation
import Synchronization

/// A clock that can be moved, so a staged visit can lapse without a real 46 minute wait.
private final class MovableClock: Sendable {
    private let base: @Sendable () -> Date
    private let shift = Mutex<TimeInterval>(0)

    init(_ base: @escaping @Sendable () -> Date) {
        self.base = base
    }

    func now() -> Date {
        base().addingTimeInterval(shift.withLock { $0 })
    }

    func advance(seconds: TimeInterval) {
        shift.withLock { $0 += seconds }
    }
}

/// Reaching any screen in any state, for DEBUG launches and UI tests. None of this is in Release.
extension LocalClinicService {
    private static let lapseSeconds = TimeInterval(46 * 60)

    /// The same sentences the web demo uses, so a staged visit is one a patient could have had.
    private struct Script {
        let symptoms: [String]
        let refill: String
        let emergency: String
        let decline: String

        static func forLanguage(_ language: String) -> Script {
            language == "ar"
                ? Script(
                    symptoms: ["عندي حرارة وكحة من ثلاث أيام", "٦", "بنادول", "لا"],
                    refill: "أبي حبوب الضغط المعتادة",
                    emergency: "عندي ألم في الصدر ينتشر إلى ذراعي", decline: "لا")
                : Script(
                    symptoms: ["I have a fever and cough for three days", "6", "panadol", "no"],
                    refill: "I need my usual blood pressure tablets.",
                    emergency: "Chest pain going to my left arm.", decline: "no")
        }
    }

    /// A service signed in as `patientId` with one visit at `stage`, reached by walking the real
    /// engine with real chat messages. `confirmed` only speaks at `.intake`: false is the
    /// opening line, true is a chat finished and confirmed. Every later stage needs both.
    ///
    /// `.refill` needs a patient with active medicines, such as P002. It throws for anyone else,
    /// because the refill route would not answer them either.
    public static func staged(
        patientId: String = "P001", stage: VisitStage, confirmed: Bool = false,
        clock: @escaping @Sendable () -> Date = { Date() },
        store: any ClinicStore = MemoryClinicStore(), language: String? = nil
    ) async throws -> (service: LocalClinicService, visitId: String) {
        let moving = MovableClock(clock)
        let service = LocalClinicService(clock: { moving.now() }, store: store)
        try await service.resetDemo()
        let visitId = try await service.walk(
            patientId: patientId, to: stage, confirmed: confirmed, language: language, clock: moving)
        return (service, visitId)
    }

    private func walk(
        patientId: String, to stage: VisitStage, confirmed: Bool, language: String?,
        clock moving: MovableClock
    ) throws -> String {
        guard let row = state.clinic.patient(patientId) else {
            throw ClinicError(status: 404, code: "unknown_qid", message: "No demo patient has this QID.")
        }
        _ = try authVerify(qid: row.qidDemo, otp: ClinicData.bundled.constants.demoOtp)
        let opened = try createVisit(patientId: nil)
        let visitId = opened.visitId
        let script = Script.forLanguage(language ?? opened.language)

        switch stage {
        case .intake where !confirmed:
            return visitId
        case .emergency:
            try require(sendChat(visitId: visitId, text: script.emergency).emergency, stage)
            return visitId
        case .refill:
            try require(sendChat(visitId: visitId, text: script.refill).refill != nil, stage)
            return visitId
        case .cancelled:
            state.clinic.updateVisit(visitId) { $0.status = .cancelled }  // No route cancels one.
            settle()
            return visitId
        default:
            break
        }

        try chatToIntake(visitId: visitId, script: script)
        _ = try confirmIntake(visitId: visitId, service: nil)
        if stage == .intake { return visitId }

        _ = try reserve(visitId: visitId, centreId: row.registeredCentreId)
        if stage == .reserved { return visitId }
        if stage == .expired {
            moving.advance(seconds: Self.lapseSeconds)
            try require(getVisit(visitId: visitId).stage == .expired, stage)
            return visitId
        }

        _ = try arrive(visitId: visitId, body: .button)
        while try getVisit(visitId: visitId).stage != stage {
            guard case .moved = try demoNextStep(visitId: visitId) else {
                try require(false, stage)
                break
            }
        }
        return visitId
    }

    private func chatToIntake(visitId: String, script: Script) throws {
        var answers = script.symptoms[...]
        while try getVisit(visitId: visitId).intake == nil {
            _ = try sendChat(visitId: visitId, text: answers.popFirst() ?? script.decline)
        }
    }

    private func require(_ reached: Bool, _ stage: VisitStage) throws {
        guard reached else {
            throw ClinicError(
                status: 409, code: "not_staged", message: "This patient cannot reach \(stage.rawValue).")
        }
    }

    // For tests

    /// Lets a test reach state no patient route can, as the exporters write to the temp database.
    func testing<Value: Sendable>(
        _ body: @Sendable (inout LocalState, inout QueueEngine) throws -> Value
    ) rethrows -> Value {
        defer { settle() }
        return try body(&state, &engine)
    }

    /// Stands in for a session token, so a replay can act as several people on one clinic.
    func adoptSession(_ subject: SessionSubject?) {
        state.subject = subject
        settle()
    }
}
#endif
