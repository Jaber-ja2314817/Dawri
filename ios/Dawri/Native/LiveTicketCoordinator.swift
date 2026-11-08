import DawriCore
import Foundation

/// Keeps the Live Activity and the local notifications in step with the visits the app reads.
/// `AppModel` holds one and feeds it every visit it reads, the newest live visit while the app is
/// in front, the scene coming back, a language switch, an emergency, a visit that is gone and
/// signing out. What to do is `LiveTicketRules` and `NotificationPlan`, both tested in DawriCore.
///
/// Work runs one piece at a time in the order it came, because each piece reads what the system
/// has running and then changes it, and two at once could start two activities for one visit.
@MainActor
final class LiveTicketCoordinator {
    private let live: any TicketLiveActivities
    private let notifier: any VisitNotifying
    private let service: any ClinicService
    private let driver: (any DemoDriving)?
    private let lang: @MainActor () -> Lang
    private let now: @Sendable () -> Date

    /// The last read of each visit, to see the arrival and changes.
    private var seen: [String: Visit] = [:]
    /// The newest visit with a live ticket, which the app-wide follower watches.
    private(set) var followed: String?
    private var appActive = true
    private var tail: Task<Void, Never>?

    init(
        live: any TicketLiveActivities, notifier: any VisitNotifying, service: any ClinicService,
        driver: (any DemoDriving)?, lang: @escaping @MainActor () -> Lang,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.live = live
        self.notifier = notifier
        self.service = service
        self.driver = driver
        self.lang = lang
        self.now = now
    }

    /// Runs `work` after everything queued before it.
    private func enqueue(_ work: @escaping @MainActor () async -> Void) {
        let previous = tail
        tail = Task {
            await previous?.value
            await work()
        }
    }

    /// Waits for everything queued so far, for the probe and for tests.
    func settled() async {
        await tail?.value
    }

    // Visits read

    /// Every visit any screen or the follower read.
    func observe(_ visit: Visit) {
        if LiveTicketRules.isLive(visit) {
            followed = visit.visitId
        } else if followed == visit.visitId {
            followed = nil
        }
        let lang = lang()
        enqueue { [weak self] in await self?.apply(visit, lang: lang) }
    }

    private func apply(_ visit: Visit, lang: Lang) async {
        let id = visit.visitId
        let previous = seen[id]
        seen[id] = visit
        var plan: [DemoPlannedStep]?
        if LiveTicketRules.isLive(visit), let driver {
            plan = try? await driver.demoPlan(visitId: id)
        }
        let moment = now()
        let running = await live.running().last { $0.visitId == id }
        let decision = LiveTicketRules.decide(
            visit: visit, lang: lang, now: moment, nextStepAt: plan.flatMap(LiveTicketRules.nextStepAt),
            running: running)
        await perform(decision, visitId: id, lang: lang)

        guard LiveTicketRules.isLive(visit) else {
            // Completion, an emergency, a refill, an expiry or a cancellation: nothing is ahead.
            if visit.status != .reserved, visit.status != .intake {
                await notifier.cancel(visitId: id)
            }
            return
        }
        // The arrival moment: the ticket has just become active. The only place permission is
        // asked, so a launch never shows the prompt.
        if previous?.status == .reserved {
            await notifier.requestAuthorization()
        }
        if let plan {
            await notifier.replace(
                visitId: id, with: NotificationPlan.notices(plan: plan, visit: visit, lang: lang, now: moment))
        } else if !appActive, let notice = NotificationPlan.observed(previous: previous, next: visit, lang: lang) {
            // A clinic server: nothing can be known ahead, so only a change seen while the app
            // still runs behind the scenes is posted.
            await notifier.post(notice)
        }
    }

    private func perform(_ decision: LiveTicketDecision, visitId: String, lang: Lang) async {
        switch decision {
        case .none:
            break
        case .start(let state, let staleDate):
            await live.start(visitId: visitId, lang: lang, state: state, staleDate: staleDate)
        case .update(let state, let alert, let staleDate):
            await live.update(visitId: visitId, state: state, alert: alert, staleDate: staleDate)
        case .restart(let state, let staleDate):
            await live.end(visitId: visitId, final: nil, dismissal: .immediate)
            await live.start(visitId: visitId, lang: lang, state: state, staleDate: staleDate)
        case .end(let final, let dismissal):
            await live.end(visitId: visitId, final: final, dismissal: dismissal)
        }
    }

    // Endings

    /// An emergency, or a visit that is gone: its activity ends at once and nothing is ahead.
    func end(visitId: String) {
        seen[visitId] = nil
        if followed == visitId { followed = nil }
        enqueue { [live, notifier] in
            await live.end(visitId: visitId, final: nil, dismissal: .immediate)
            await notifier.cancel(visitId: visitId)
        }
    }

    /// Signing out or a demo reset: every activity and every notice goes.
    func endAll() {
        seen.removeAll()
        followed = nil
        enqueue { [live, notifier] in
            await live.endAll(except: [])
            await notifier.cancelAll(except: [])
        }
    }

    /// The language changed: an activity's language is fixed for its life, so a live one ends and
    /// a new one starts in the new language, and the pending notices are written again in it.
    func languageChanged() {
        guard let id = followed, let visit = seen[id] else { return }
        observe(visit)
    }

    // Launch and the scene

    /// At launch, and when the app comes back: ends every activity and clears every notice whose
    /// visit is not live, so old ones never pile up or fire for a visit that is over or gone, and
    /// reads the followed visit again to catch up.
    func reconcile() async {
        let rows = (try? await service.listVisits()) ?? []
        let liveIds = Set(rows.filter { $0.active && Self.liveStages.contains($0.stage) }.map(\.visitId))
        enqueue { [live, notifier] in
            await live.endAll(except: liveIds)
            await notifier.cancelAll(except: liveIds)
        }
        if followed == nil {
            followed = rows.filter { liveIds.contains($0.visitId) }
                .max { $0.createdAt < $1.createdAt }?.visitId
        }
        await refresh()
    }

    private static let liveStages: Set<VisitStage> = [.triage, .doctor, .pharmacy]

    func sceneChanged(active: Bool) {
        appActive = active
    }

    /// Reads the followed visit once and applies it. A visit that is gone ends; any other failure
    /// is left to the screens, which show it.
    private func refresh() async {
        guard let id = followed else { return }
        do {
            observe(try await service.getVisit(visitId: id))
        } catch let error as ClinicError where error.status == 404 {
            end(visitId: id)
        } catch {}
    }

    /// While the app is in front: follows the newest live visit through its updates, so the
    /// activity keeps moving when no screen watches the visit, as on Home. Returns when the
    /// surrounding task is cancelled.
    func follow() async {
        await reconcile()
        while !Task.isCancelled {
            guard let id = followed else {
                // Nothing live yet: look again in a moment, as a screen may start one.
                try? await Task.sleep(for: .seconds(2))
                continue
            }
            for await update in await service.visitUpdates(visitId: id) {
                if Task.isCancelled || followed != id { break }
                if update != .dropped { await refresh() }
            }
            if Task.isCancelled { return }
            try? await Task.sleep(for: .seconds(4))
            if followed == id { await refresh() }
        }
    }

    #if DEBUG
    // DEBUG probe

    /// Activities, pending notices and the followed visit's demo plan on one line, for the
    /// DEBUG probe. Offsets are whole seconds from now.
    func probe() async -> String {
        await settled()
        let activities = await live.running().map { running in
            [
                running.visitId, running.state.number ?? "-", running.state.stage.rawValue,
                running.state.ticketState?.rawValue ?? "-", running.lang.rawValue,
                running.state.peopleAhead.map(String.init) ?? "-",
            ].joined(separator: ",")
        }
        let moment = Date()
        func offset(_ date: Date) -> String { String(Int(date.timeIntervalSince(moment).rounded())) }
        let snapshot = await notifier.snapshot()
        let pending = (snapshot?.pending ?? []).map { item in
            "\(item.id)@\(item.fireAt.map(offset) ?? "-")@\(item.key)"
        }
        var plan: [String] = []
        if let id = followed, let driver, let steps = try? await driver.demoPlan(visitId: id) {
            plan = steps.enumerated().map { index, step in
                "\(index):\(step.kind.rawValue):\(step.stage.rawValue)@\(step.performedAt == nil ? offset(step.dueAt) : "done")"
            }
        }
        return [
            "activities=\(activities.joined(separator: ";"))",
            "pending=\(pending.joined(separator: ";"))",
            "auth=\(snapshot?.authorization ?? "none")",
            "followed=\(followed ?? "-")",
            "plan=\(plan.joined(separator: ";"))",
        ].joined(separator: " | ")
    }
    #endif
}
