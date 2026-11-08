import ActivityKit
import DawriCore
import Foundation

/// The ticket's Live Activity on the Lock Screen and the Dynamic Island. Local updates only,
/// never push: the app asks for no push token and has no push entitlement. What to do is decided
/// by `LiveTicketRules` in `LiveTicketCoordinator`, and this only does it. See iOS Design
/// section 9.
protocol TicketLiveActivities: Sendable {
    /// Every activity still showing, one per visit, as the system has them now. After a relaunch
    /// this is how the app finds them again.
    func running() async -> [LiveTicketRunning]
    func start(visitId: String, lang: Lang, state: TicketLiveState, staleDate: Date) async
    /// `alert` expands the Island and plays the default sound, only on the move into called.
    func update(visitId: String, state: TicketLiveState, alert: Bool, staleDate: Date) async
    /// Ends the visit's activity, with its final state, or nil to keep the last one.
    func end(visitId: String, final: TicketLiveState?, dismissal: LiveDismissal) async
    /// Ends and removes every activity of this app whose visit is not in `keeping`, ended ones
    /// included, so test runs and relaunches never leave old ones behind.
    func endAll(except keeping: Set<String>) async
}

/// A build with no Live Activity.
struct NoTicketLive: TicketLiveActivities {
    func running() async -> [LiveTicketRunning] { [] }
    func start(visitId: String, lang: Lang, state: TicketLiveState, staleDate: Date) async {}
    func update(visitId: String, state: TicketLiveState, alert: Bool, staleDate: Date) async {}
    func end(visitId: String, final: TicketLiveState?, dismissal: LiveDismissal) async {}
    func endAll(except keeping: Set<String>) async {}
}

/// The real activity through `ActivityKit`. It keeps nothing of its own: every call reads
/// `Activity.activities`, so the system is the one record of what runs.
struct ActivityTicketLive: TicketLiveActivities {
    private typealias TicketActivity = Activity<TicketActivityAttributes>

    init() {}

    /// Activities the patient can still see, newest last.
    private func showing(_ visitId: String? = nil) -> [TicketActivity] {
        TicketActivity.activities.filter { activity in
            let state = activity.activityState
            return (state == .active || state == .stale)
                && (visitId == nil || activity.attributes.visitId == visitId)
        }
    }

    func running() async -> [LiveTicketRunning] {
        showing().map { activity in
            LiveTicketRunning(
                visitId: activity.attributes.visitId, lang: activity.attributes.lang,
                state: activity.content.state, staleDate: activity.content.staleDate)
        }
    }

    func start(visitId: String, lang: Lang, state: TicketLiveState, staleDate: Date) async {
        // One per visit: anything already showing for it goes first.
        for activity in showing(visitId) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        // The patient can turn Live Activities off in Settings, and then there are none.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        do {
            _ = try TicketActivity.request(
                attributes: TicketActivityAttributes(lang: lang, visitId: visitId),
                content: ActivityContent(state: state, staleDate: staleDate),
                pushType: nil)
        } catch {
            // Refused by the system, for example over its limit. The app works without it.
        }
    }

    func update(visitId: String, state: TicketLiveState, alert: Bool, staleDate: Date) async {
        let content = ActivityContent(state: state, staleDate: staleDate)
        for activity in showing(visitId) {
            if alert {
                let lang = activity.attributes.lang
                let config = AlertConfiguration(
                    title: LocalizedStringResource(stringLiteral: Strings.bundled.translate(lang, "common.product")),
                    body: LocalizedStringResource(stringLiteral: Strings.bundled.translate(lang, "live.go")),
                    sound: .default)
                await activity.update(content, alertConfiguration: config)
            } else {
                await activity.update(content)
            }
        }
    }

    func end(visitId: String, final: TicketLiveState?, dismissal: LiveDismissal) async {
        let policy: ActivityUIDismissalPolicy = switch dismissal {
        case .immediate: .immediate
        case .after(let date): .after(date)
        }
        for activity in showing(visitId) {
            await activity.end(final.map { ActivityContent(state: $0, staleDate: nil) }, dismissalPolicy: policy)
        }
    }

    func endAll(except keeping: Set<String>) async {
        for activity in TicketActivity.activities
        where activity.activityState != .dismissed && !keeping.contains(activity.attributes.visitId) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
