import Foundation

/// When an ended activity leaves the Lock Screen.
public enum LiveDismissal: Sendable, Equatable {
    /// At once: an emergency, a visit that is gone, or anything that is not a live ticket.
    case immediate
    /// At this moment: a completed visit stays on the Lock Screen for 15 minutes.
    case after(Date)
}

/// A visit's activity as it runs now, read back from the system.
public struct LiveTicketRunning: Sendable, Equatable {
    public var visitId: String
    /// Fixed for the activity's life.
    public var lang: Lang
    public var state: TicketLiveState
    public var staleDate: Date?

    public init(visitId: String, lang: Lang, state: TicketLiveState, staleDate: Date?) {
        self.visitId = visitId
        self.lang = lang
        self.state = state
        self.staleDate = staleDate
    }
}

/// What to do with a visit's activity after reading the visit.
public enum LiveTicketDecision: Sendable, Equatable {
    case none
    case start(TicketLiveState, staleDate: Date)
    /// `alert` is true only on the move into called, so the Island expands once.
    case update(TicketLiveState, alert: Bool, staleDate: Date)
    /// The running activity is in the other language. Its language is fixed for its life, so it
    /// ends at once and this one starts in the new language.
    case restart(TicketLiveState, staleDate: Date)
    /// The final state, or nil to keep the last one, and when it leaves the Lock Screen.
    case end(TicketLiveState?, dismissal: LiveDismissal)
}

/// What the Live Activity shows in each presentation, apart from staleness, which the system
/// reports separately through `context.isStale`.
public enum LiveTicketPhase: String, Sendable, Equatable, CaseIterable {
    case active, called, serving
    /// The visit has moved on and its next ticket has no number yet.
    case between
    /// The visit is complete. Only the final state of an ended activity has this.
    case ended
}

/// The rules of the ticket's Live Activity, iOS Design section 9. Pure, so `swift test` proves
/// them. The app's `LiveTicketCoordinator` reads a visit, asks `decide`, and does what it says.
///
/// - No activity while reserved, because a reserved ticket has no number, and none on an
///   emergency, a refill, an expired or a cancelled visit.
/// - It starts on an activated ticket with a number, and updates on any change.
/// - It alerts only on the move into called.
/// - It goes stale at the next planned demo step, or after a short bound when no plan is known,
///   as with a clinic server, which sends nothing while the app is not running.
/// - It ends at completion and stays 15 minutes, and ends at once on anything else.
public enum LiveTicketRules {
    /// How long a completed visit's activity stays on the Lock Screen.
    public static let completeDismissal: TimeInterval = 15 * 60
    /// The stale date when the next change is not known ahead.
    public static let staleBound: TimeInterval = 120

    /// The visit statuses an activity runs through.
    public static let liveStatuses: Set<VisitStatus> = [.inTriage, .inDoctor, .inPharmacy]

    public static func isLive(_ visit: Visit) -> Bool {
        liveStatuses.contains(visit.status)
    }

    /// What the activity shows for a live visit, in `lang`. Between stages the number and the
    /// ticket state are nil, as S10 shows `ticket.nextStep` then.
    public static func state(for visit: Visit, lang: Lang) -> TicketLiveState {
        let ticket = TicketRules.shownTicket(visit).flatMap { $0.number == nil ? nil : $0 }
        let counter = visit.goTo.map { lang == .ar ? $0.counterAr : $0.counter }
            ?? ticket.map { lang == .ar ? $0.counterAr : $0.counter }
            ?? ""
        return TicketLiveState(
            number: ticket?.number, stage: visit.stage, peopleAhead: ticket?.peopleAhead,
            estWaitMin: ticket?.estWaitMin, counter: counter, ticketState: ticket?.state,
            centreName: visit.centre.map { centreName($0, lang: lang) } ?? "")
    }

    /// The last state of a completed visit: `complete.title`, with no number.
    public static func finalState(for visit: Visit, lang: Lang) -> TicketLiveState {
        TicketLiveState(
            number: nil, stage: .completed, peopleAhead: nil, estWaitMin: nil, counter: "",
            ticketState: nil,
            centreName: visit.centre.map { centreName($0, lang: lang) } ?? "")
    }

    public static func phase(_ state: TicketLiveState) -> LiveTicketPhase {
        if state.stage == .completed { return .ended }
        guard state.number != nil, let ticketState = state.ticketState else { return .between }
        switch ticketState {
        case .called: return .called
        case .serving: return .serving
        default: return .active
        }
    }

    /// The first planned step that has not run, which is when the demo clinic moves next.
    public static func nextStepAt(_ plan: [DemoPlannedStep]) -> Date? {
        plan.first { $0.performedAt == nil }?.dueAt
    }

    /// The next planned step while it is ahead, or `staleBound` from now.
    public static func staleDate(now: Date, nextStepAt: Date?) -> Date {
        if let nextStepAt, nextStepAt > now { return nextStepAt }
        return now.addingTimeInterval(staleBound)
    }

    public static func decide(
        visit: Visit, lang: Lang, now: Date, nextStepAt: Date?, running: LiveTicketRunning?
    ) -> LiveTicketDecision {
        switch visit.status {
        case .inTriage, .inDoctor, .inPharmacy:
            let state = Self.state(for: visit, lang: lang)
            let stale = Self.staleDate(now: now, nextStepAt: nextStepAt)
            let numbered = state.number != nil
            guard let running else {
                return numbered ? .start(state, staleDate: stale) : .none
            }
            if running.lang != lang {
                return numbered ? .restart(state, staleDate: stale) : .end(nil, dismissal: .immediate)
            }
            let alert = state.ticketState == .called && running.state.ticketState != .called
            if state != running.state {
                return .update(state, alert: alert, staleDate: stale)
            }
            if needsNewStaleDate(running.staleDate, stale, now: now, nextStepAt: nextStepAt) {
                return .update(state, alert: false, staleDate: stale)
            }
            return .none
        case .completed:
            guard running != nil else { return .none }
            return .end(
                finalState(for: visit, lang: lang),
                dismissal: .after(now.addingTimeInterval(completeDismissal)))
        case .intake, .reserved, .redirectedEmergency, .deflectedRefill, .expired, .cancelled:
            return running == nil ? .none : .end(nil, dismissal: .immediate)
        }
    }

    /// With no change to show, the stale date still moves when the plan moved, and, with no plan,
    /// once half its bound has gone, so a watched ticket never goes stale while the app runs.
    private static func needsNewStaleDate(
        _ current: Date?, _ next: Date, now: Date, nextStepAt: Date?
    ) -> Bool {
        guard let current else { return true }
        if let nextStepAt, nextStepAt > now { return current != next }
        return current.timeIntervalSince(now) < staleBound / 2
    }
}
