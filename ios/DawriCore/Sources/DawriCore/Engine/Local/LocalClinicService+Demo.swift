import Foundation

/// The demo clinic's clock and controls. See `DemoClinic` for what each step does.
extension LocalClinicService: DemoDriving {
    /// Plans the visit when it arrives. A patient the demo cannot plan for keeps their ticket.
    func startDemoRun(visitId: String, ticket: TicketRecord) {
        guard demoClinicEnabled else { return }
        state.demoRuns[visitId] = try? DemoClinic.plan(
            state, visitId: visitId, ticket: ticket,
            start: ClinicTime.microseconds(of: clock()))
    }

    /// Tries the run's next step, stamped at `moment`. A pinned engine is what makes a step that
    /// fell due while the app was gone carry its own time and not the time the app came back.
    private func step(_ run: inout DemoRun, at moment: Int64) -> DemoClinic.Result {
        guard let step = run.pending else { return .stopped }
        var pinned = QueueEngine(clock: { ClinicTime.date(microseconds: moment) }, newId: newId)
        let result = DemoClinic.perform(step.kind, visitId: run.visitId, &pinned, &state)
        pending += pinned.takeMessages()
        switch result {
        case .moved:
            audit(step.kind, run, at: moment)
            run.markPerformed(at: moment)
        case .nothingToDo:
            run.markPerformed(at: moment)
        case .finishedEarly:
            audit(step.kind, run, at: moment)
            run.markPerformed(at: moment)
            run.status = .finished
        case .blocked:
            break
        case .stopped:
            run.status = .cancelled
        }
        return result
    }

    private func audit(_ kind: DemoStepKind, _ run: DemoRun, at moment: Int64) {
        state.audit(
            run.visitId,
            [
                AiEvent(
                    type: "demo.step",
                    payload: ["staff_id": .string(DemoClinic.actor), "step": .string(kind.rawValue)])
            ],
            at: ClinicTime.date(microseconds: moment))
    }

    /// Runs what is due across every run, oldest first, so two visits at one counter meet in
    /// the order they would have. A blocked step tries again one gap later, and that stays
    /// inside this loop when the app was gone for longer than that.
    func runDueDemoSteps(until now: Int64) {
        while let due = state.demoRuns.values
            .compactMap({ run in run.pending.map { (run.visitId, $0.dueMicros) } })
            .filter({ $0.1 <= now })
            .min(by: { ($0.1, $0.0) < ($1.1, $1.0) })
        {
            guard var run = state.demoRuns[due.0] else { return }
            if step(&run, at: due.1) == .blocked {
                run.rebase(nextTo: due.1 + DemoClinic.stepMicros)
            }
            state.demoRuns[due.0] = run
        }
    }

    /// An emergency stops the run at once, on this visit and on any other of this patient's, and
    /// no further step fires. A dependent's visit is someone else's, as in `leave_the_queue`.
    func cancelDemoRuns(patientId: String) {
        for (visitId, run) in state.demoRuns where run.status == .running {
            guard state.clinic.visit(visitId)?.patientId == patientId else { continue }
            state.demoRuns[visitId]?.status = .cancelled
        }
    }

    @discardableResult
    public func demoNextStep(visitId: String) throws -> DemoStepOutcome {
        catchUp()
        defer { settle() }
        _ = try patientVisit(visitId)
        guard var run = state.demoRuns[visitId] else { return .finished }
        defer { state.demoRuns[visitId] = run }
        let now = ClinicTime.microseconds(of: clock())
        while let pending = run.pending {
            switch step(&run, at: now) {
            case .moved, .finishedEarly:
                run.rebase(nextTo: now + DemoClinic.stepMicros)
                return .moved(pending.kind)
            case .nothingToDo:
                continue
            case .blocked:
                run.rebase(nextTo: now + DemoClinic.stepMicros)
                return .waiting
            case .stopped:
                return .finished
            }
        }
        return .finished
    }

    public func demoPlan(visitId: String) throws -> [DemoPlannedStep] {
        catchUp()
        defer { settle() }
        _ = try patientVisit(visitId)
        return (state.demoRuns[visitId]?.steps ?? []).map { step in
            DemoPlannedStep(
                kind: step.kind, stage: step.stage,
                dueAt: ClinicTime.date(microseconds: step.dueMicros),
                performedAt: step.performedMicros.map(ClinicTime.date(microseconds:)))
        }
    }

    /// `reset` in backend/routers/demo.py. Open streams stay open and hear about it, as open
    /// consoles do there.
    public func resetDemo() throws {
        var fresh = try LocalState.fresh(engine: &engine, subject: state.subject)
        _ = engine.takeMessages()
        fresh.audit(
            nil,
            [AiEvent(type: "demo.reset", payload: ["staff_id": .string(DemoClinic.actor)])],
            at: clock())
        state = fresh
        notifyAll()
        settle()
    }
}
