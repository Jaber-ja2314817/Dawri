import DawriCore
import Foundation
import UserNotifications

/// Local notifications for a visit: `notify.next` when the patient is about to be called, and
/// `notify.stage` when the next stage is ready. On this phone the demo clinic's plan is known, so
/// `NotificationPlan` works them out ahead and they need no network. A clinic server has no push,
/// so there nothing is scheduled ahead and a notice is posted only for a change the app saw while
/// it still ran, as Settings says. What to schedule is decided in `LiveTicketCoordinator`.
protocol VisitNotifying: Sendable {
    /// Asks for alerts and sounds, if the patient has not been asked yet. Called only at the
    /// arrival moment, never at launch.
    func requestAuthorization() async
    /// Replaces every pending notice of the visit with these, so a demo next step, a rebased
    /// plan and a language switch all come out right. Nothing happens without permission.
    func replace(visitId: String, with notices: [PlannedNotice]) async
    /// Posts one notice at once.
    func post(_ notice: PlannedNotice) async
    /// Removes the visit's pending and delivered notices.
    func cancel(visitId: String) async
    /// Removes every notice of this app except those of `visitIds`. Signing out and a demo reset
    /// keep none. A launch keeps the live visits', so a notice left by a visit that has ended or
    /// is gone, while the app was not running to cancel it, never fires.
    func cancelAll(except visitIds: Set<String>) async
    /// The pending ids with their fire dates, oldest first, and the permission, for the DEBUG
    /// probe. Nil when this build sends none.
    func snapshot() async -> NoticeSnapshot?
}

struct NoticeSnapshot: Sendable, Equatable {
    var authorization: String
    var pending: [(id: String, key: String, fireAt: Date?)]

    static func == (lhs: NoticeSnapshot, rhs: NoticeSnapshot) -> Bool {
        lhs.authorization == rhs.authorization
            && lhs.pending.map(\.id) == rhs.pending.map(\.id)
            && lhs.pending.map(\.fireAt) == rhs.pending.map(\.fireAt)
    }
}

/// A build that sends no notifications, and asks for no permission.
struct NoVisitNotifier: VisitNotifying {
    func requestAuthorization() async {}
    func replace(visitId: String, with notices: [PlannedNotice]) async {}
    func post(_ notice: PlannedNotice) async {}
    func cancel(visitId: String) async {}
    func cancelAll(except visitIds: Set<String>) async {}
    func snapshot() async -> NoticeSnapshot? { nil }
}

/// Local notifications through `UserNotifications`. The system default sound, the default
/// interruption level, and nothing about the patient's health in the text.
struct LocalVisitNotifier: VisitNotifying {
    private static let keyInfo = "key"
    private static let fireInfo = "fireAt"

    init() {}

    private var center: UNUserNotificationCenter { .current() }

    private func allowed() async -> Bool {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: true
        default: false
        }
    }

    func requestAuthorization() async {
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    private func ids(withPrefix prefix: String) async -> (pending: [String], delivered: [String]) {
        let pending = await center.pendingNotificationRequests().map(\.identifier)
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        return (pending.filter { $0.hasPrefix(prefix) }, delivered.filter { $0.hasPrefix(prefix) })
    }

    func replace(visitId: String, with notices: [PlannedNotice]) async {
        let old = await ids(withPrefix: NotificationPlan.prefix(visitId: visitId)).pending
        center.removePendingNotificationRequests(withIdentifiers: old)
        guard await allowed() else { return }
        let now = Date()
        for notice in notices {
            guard let fireAt = notice.fireAt, fireAt.timeIntervalSince(now) >= 1 else { continue }
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: fireAt.timeIntervalSince(now), repeats: false)
            try? await center.add(request(notice, trigger: trigger))
        }
    }

    func post(_ notice: PlannedNotice) async {
        guard await allowed() else { return }
        try? await center.add(request(notice, trigger: nil))
    }

    private func request(_ notice: PlannedNotice, trigger: UNNotificationTrigger?) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.sound = .default
        var info: [String: Any] = [Self.keyInfo: notice.key]
        if let fireAt = notice.fireAt { info[Self.fireInfo] = fireAt.timeIntervalSince1970 }
        content.userInfo = info
        return UNNotificationRequest(identifier: notice.id, content: content, trigger: trigger)
    }

    func cancel(visitId: String) async {
        let found = await ids(withPrefix: NotificationPlan.prefix(visitId: visitId))
        center.removePendingNotificationRequests(withIdentifiers: found.pending)
        center.removeDeliveredNotifications(withIdentifiers: found.delivered)
    }

    func cancelAll(except visitIds: Set<String>) async {
        let found = await ids(withPrefix: NotificationPlan.prefix)
        let kept = visitIds.map(NotificationPlan.prefix(visitId:))
        func goes(_ id: String) -> Bool { !kept.contains { id.hasPrefix($0) } }
        center.removePendingNotificationRequests(withIdentifiers: found.pending.filter(goes))
        center.removeDeliveredNotifications(withIdentifiers: found.delivered.filter(goes))
    }

    func snapshot() async -> NoticeSnapshot? {
        let status = await center.notificationSettings().authorizationStatus
        let name = switch status {
        case .notDetermined: "notDetermined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(NotificationPlan.prefix) }
            .map { request -> (id: String, key: String, fireAt: Date?) in
                let info = request.content.userInfo
                return (
                    request.identifier, info[Self.keyInfo] as? String ?? "",
                    (info[Self.fireInfo] as? Double).map(Date.init(timeIntervalSince1970:)))
            }
            .sorted { ($0.fireAt ?? .distantFuture, $0.id) < ($1.fireAt ?? .distantFuture, $1.id) }
        return NoticeSnapshot(authorization: name, pending: pending)
    }
}

/// Shows a notice that arrives while the app is open in Notification Centre only: no banner and
/// no sound over a screen that already shows the change.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate, Sendable {
    static let shared = NotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.list]
    }
}
