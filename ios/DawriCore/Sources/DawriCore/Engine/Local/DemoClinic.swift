import Foundation

/// One move of the demo clinic. There are no staff behind a ticket on the phone, so this stands
/// in for them, says so wherever it is recorded, and goes through `QueueEngine` for every move.
public enum DemoStepKind: String, Sendable, Codable, Equatable, CaseIterable {
    case queueMoves = "queue_moves"
    case callTriage = "call_triage"
    case serveTriage = "serve_triage"
    case toDoctor = "to_doctor"
    case callDoctor = "call_doctor"
    case consult
    case callPharmacy = "call_pharmacy"
    case dispense
}

/// A step as it is stored, with the stage the visit reaches when it runs.
public struct DemoStep: Sendable, Codable, Equatable {
    public var kind: DemoStepKind
    public var stage: VisitStage
    public var dueMicros: Int64
    public var performedMicros: Int64?

    enum CodingKeys: String, CodingKey {
        case kind, stage
        case dueMicros = "due_micros"
        case performedMicros = "performed_micros"
    }
}

/// A visit's plan. It is persisted, so steps that fell due while the app was gone still run.
public struct DemoRun: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case running
        case finished
        /// An emergency stopped it. No further step fires.
        case cancelled
    }

    public var visitId: String
    public var steps: [DemoStep]
    public var next: Int
    public var status: Status

    enum CodingKeys: String, CodingKey {
        case visitId = "visit_id"
        case steps, next, status
    }

    /// The step to run next, while the run is alive.
    var pending: DemoStep? {
        status == .running && next < steps.count ? steps[next] : nil
    }

    /// Puts the next step at `micros` and keeps the gaps after it.
    mutating func rebase(nextTo micros: Int64) {
        guard let pending else { return }
        let shift = micros - pending.dueMicros
        for index in next..<steps.count { steps[index].dueMicros += shift }
    }

    mutating func markPerformed(at micros: Int64) {
        steps[next].performedMicros = micros
        next += 1
        if next >= steps.count { status = .finished }
    }
}

/// `demoPlan`'s row: what a later phase needs to schedule a local notification ahead of time.
public struct DemoPlannedStep: Sendable, Equatable {
    public var kind: DemoStepKind
    public var stage: VisitStage
    public var dueAt: Date
    /// Nil until the step has run.
    public var performedAt: Date?
}

/// What `demoNextStep` did.
public enum DemoStepOutcome: Sendable, Equatable {
    case moved(DemoStepKind)
    /// A real patient is ahead or the counter is busy, so nothing moved.
    case waiting
    /// There is no step left: the visit is done, an emergency stopped it, or it has no plan.
    case finished
}

/// The controls of the demo clinic. They are not on `ClinicService`, because a real clinic
/// server has staff and `RemoteClinicService` will not conform.
public protocol DemoDriving: Sendable {
    /// Runs the next step now, and moves the later ones so they keep their gaps.
    @discardableResult
    func demoNextStep(visitId: String) async throws -> DemoStepOutcome
    /// Every planned step with its time and the stage it reaches.
    func demoPlan(visitId: String) async throws -> [DemoPlannedStep]
    /// Back to a fresh demo. The signed-in patient stays signed in, as the web keeps sessions.
    func resetDemo() async throws
}

/// The steps themselves. Patient-facing strings never come from here, only audit rows, and the
/// actor on them says demo, as `demo:` does for `fast_forward` in backend/routers/demo.py.
enum DemoClinic {
    static let stepMicros: Int64 = 15 * 1_000_000
    static let actor = "demo:clinic"

    enum Result: Equatable {
        case moved
        /// Nothing was left to do here, so the step is used up and the next one stands.
        case nothingToDo
        case blocked
        /// The visit finished here, with the rest of the plan unused.
        case finishedEarly
        case stopped
    }

    /// `_blocked_here`: someone real stands before this visit on its own counter.
    private static func blockedHere(_ rows: [QueueRow], visitId: String) -> Bool {
        for row in rows {
            if row.visitId == visitId { return false }
            if row.state == .called || row.state == .serving || !row.simulated { return true }
        }
        return false
    }

    /// `_blocked_on_joining`: a newcomer goes behind every real ticket of its priority or above.
    private static func blockedOnJoining(_ rows: [QueueRow], priority: Int) -> Bool {
        rows.contains {
            $0.state == .called || $0.state == .serving || (!$0.simulated && $0.priority >= priority)
        }
    }

    private static func isAtCounter(_ ticket: TicketRecord) -> Bool {
        ticket.state == .called || ticket.state == .serving
    }

    private static func simulatedAhead(_ state: ClinicState, _ ticket: TicketRecord) -> Int {
        let queue = state.activeTickets(at: ticket.counterId)
        guard let place = queue.firstIndex(where: { $0.id == ticket.id }) else { return 0 }
        return queue[..<place].count(where: \.simulated)
    }

    /// `_service` in backend/ai/handoff.py, with no nurse's edit on a phone.
    private static func service(_ state: LocalState, _ visit: VisitRecord) -> String {
        visit.service?.rawValue ?? state.chats[visit.id]?.intake?.service.rawValue ?? "other"
    }

    /// The plan for a visit that has just arrived, one step every 15 seconds from `start`.
    static func plan(
        _ state: LocalState, visitId: String, ticket: TicketRecord, start: Int64
    ) throws -> DemoRun {
        guard let visit = state.clinic.visit(visitId),
              let patient = state.clinic.patient(visit.patientId)
        else { throw ClinicError.visitNotFound }
        let prescribed = try !VisitFlow.defaultItems(state.clinic, allergies: patient.allergies).isEmpty
        var moves: [(DemoStepKind, VisitStage)] = Array(
            repeating: (.queueMoves, .triage), count: simulatedAhead(state.clinic, ticket))
        moves += [
            (.callTriage, .triage), (.serveTriage, .triage), (.toDoctor, .doctor),
            (.callDoctor, .doctor),
        ]
        moves += prescribed
            ? [(.consult, .pharmacy), (.callPharmacy, .pharmacy), (.dispense, .completed)]
            : [(.consult, .completed)]
        let steps = moves.enumerated().map { index, move in
            DemoStep(
                kind: move.0, stage: move.1, dueMicros: start + Int64(index + 1) * stepMicros,
                performedMicros: nil)
        }
        return DemoRun(visitId: visitId, steps: steps, next: 0, status: .running)
    }

    /// One step, on `engine`'s clock. A refusal from the engine is a wait: the step comes back,
    /// and a real patient is never skipped to get past it.
    static func perform(
        _ kind: DemoStepKind, visitId: String, _ engine: inout QueueEngine, _ state: inout LocalState
    ) -> Result {
        do {
            return try attempt(kind, visitId: visitId, &engine, &state)
        } catch {
            return .blocked
        }
    }

    private static func attempt(
        _ kind: DemoStepKind, visitId: String, _ engine: inout QueueEngine, _ state: inout LocalState
    ) throws -> Result {
        guard let visit = state.clinic.visit(visitId),
              !QueueEngine.noTicketStatuses.contains(visit.status),
              let ticket = engine.liveTicket(state.clinic, visitId: visitId)
        else { return .stopped }

        switch kind {
        case .queueMoves:
            guard simulatedAhead(state.clinic, ticket) > 0 else { return .nothingToDo }
            _ = try engine.completeSimulated(&state.clinic, counterId: ticket.counterId)
            return .moved

        case .callTriage, .callDoctor, .callPharmacy:
            if isAtCounter(ticket) { return .nothingToDo }
            let rows = try engine.queueSnapshot(&state.clinic, counterId: ticket.counterId)
            if blockedHere(rows, visitId: visitId) { return .blocked }
            let called = try engine.callNext(&state.clinic, counterId: ticket.counterId).called
            return called?.visitId == visitId ? .moved : .blocked

        case .serveTriage:
            guard ticket.state == .called else { return .nothingToDo }
            _ = try engine.serve(&state.clinic, ticketId: ticket.id)
            return .moved

        case .toDoctor:
            guard isAtCounter(ticket), let patient = state.clinic.patient(visit.patientId) else {
                return .blocked
            }
            let wanted = CentreRules.routedService(service(state, visit))
            guard let doctor = DoctorRules.suggest(
                state.clinic, centreId: ticket.centreId, service: wanted,
                patientLang: patient.preferredLang
            ).first else { return .blocked }
            _ = try engine.advance(
                &state.clinic, ticketId: ticket.id, nextCounterId: doctor.counterId)
            return .moved

        case .consult:
            guard isAtCounter(ticket), let patient = state.clinic.patient(visit.patientId) else {
                return .blocked
            }
            let items = try VisitFlow.defaultItems(state.clinic, allergies: patient.allergies)
            if !items.isEmpty {
                let pharmacy = try VisitFlow.pharmacyCounter(state.clinic, centreId: ticket.centreId)
                let rows = try engine.queueSnapshot(&state.clinic, counterId: pharmacy)
                if blockedOnJoining(rows, priority: ticket.priority) { return .blocked }
            }
            let moved = try VisitFlow.completeConsult(
                &engine, &state.clinic, visitId: visitId, ticket: ticket, items: items, actor: actor)
            return moved.state == .done ? .finishedEarly : .moved

        case .dispense:
            guard isAtCounter(ticket) else { return .blocked }
            _ = try VisitFlow.dispense(
                &engine, &state.clinic, visitId: visitId, ticket: ticket, actor: actor)
            return .moved
        }
    }
}
