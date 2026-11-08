import Foundation

/// One local notification, in the visit's language. The title is the product and the body says
/// only what to do next: nothing about the patient's health is ever in it.
public struct PlannedNotice: Sendable, Equatable {
    /// `dawri.<visitId>.<index>` for a planned step, so a rebased plan keeps its ids.
    public var id: String
    /// `notify.next` or `notify.stage`.
    public var key: String
    public var title: String
    public var body: String
    /// Nil posts it at once, as an observed change does.
    public var fireAt: Date?

    public init(id: String, key: String, title: String, body: String, fireAt: Date?) {
        self.id = id
        self.key = key
        self.title = title
        self.body = body
        self.fireAt = fireAt
    }
}

/// The local notifications of a visit, iOS Design section 9. On this phone the demo clinic's
/// plan is known, so they are worked out ahead from it and need no network. A clinic server has
/// no plan and no push, so there only an observed change makes one, while the app still runs.
///
/// - A call to a counter gives `notify.next`.
/// - The move to the doctor, and the consult that sends the patient to the pharmacy, give
///   `notify.stage`.
/// - The queue moving, serving, dispensing and completion give nothing.
/// - A step that has run, or whose time has passed, gives nothing.
public enum NotificationPlan {
    public static let nextKey = "notify.next"
    public static let stageKey = "notify.stage"

    /// Every id this app schedules starts with this.
    public static let prefix = "dawri."

    public static func prefix(visitId: String) -> String {
        "\(prefix)\(visitId)."
    }

    public static func id(visitId: String, index: Int) -> String {
        "\(prefix(visitId: visitId))\(index)"
    }

    /// The notice a step gives, if any.
    public static func key(for step: DemoPlannedStep) -> String? {
        switch step.kind {
        case .callTriage, .callDoctor, .callPharmacy: nextKey
        case .toDoctor: stageKey
        case .consult: step.stage == .pharmacy ? stageKey : nil
        case .queueMoves, .serveTriage, .dispense: nil
        }
    }

    /// The notices still ahead of `now` for a live visit, in plan order.
    public static func notices(
        plan: [DemoPlannedStep], visit: Visit, lang: Lang, now: Date
    ) -> [PlannedNotice] {
        guard LiveTicketRules.isLive(visit) else { return [] }
        let atCounter = TicketRules.shownTicket(visit).map { $0.state == .called || $0.state == .serving }
            ?? false
        return plan.enumerated().compactMap { index, step in
            guard step.performedAt == nil, step.dueAt > now, let key = key(for: step) else {
                return nil
            }
            // A call to the counter the patient is already at would run as nothing to do.
            if key == nextKey, atCounter, step.stage == visit.stage { return nil }
            return notice(
                id: id(visitId: visit.visitId, index: index), key: key, lang: lang, fireAt: step.dueAt)
        }
    }

    /// What a change seen while the app runs gives, when no plan is known: `notify.next` on the
    /// move into called, else `notify.stage` on a move to the next stage.
    public static func observed(previous: Visit?, next: Visit, lang: Lang) -> PlannedNotice? {
        guard let previous, previous.visitId == next.visitId, LiveTicketRules.isLive(next) else {
            return nil
        }
        let wasCalled = TicketRules.shownTicket(previous)?.state == .called
        let isCalled = TicketRules.shownTicket(next)?.state == .called
        let base = "\(prefix(visitId: next.visitId))seen.\(next.stage.rawValue)"
        if isCalled, !wasCalled || previous.stage != next.stage {
            return notice(id: "\(base).called", key: nextKey, lang: lang, fireAt: nil)
        }
        if LiveTicketRules.isLive(previous), previous.stage != next.stage {
            return notice(id: base, key: stageKey, lang: lang, fireAt: nil)
        }
        return nil
    }

    private static func notice(id: String, key: String, lang: Lang, fireAt: Date?) -> PlannedNotice {
        PlannedNotice(
            id: id, key: key, title: Strings.bundled.translate(lang, "common.product"),
            body: Strings.bundled.translate(lang, key), fireAt: fireAt)
    }
}
