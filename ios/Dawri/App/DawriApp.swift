import SwiftUI
import UserNotifications

@main
struct DawriApp: App {
    /// Owns the current model. Settings swaps it when the clinic changes.
    @State private var host = AppHost.launch()

    init() {
        // Set before the first notice can arrive. A notice that lands while the app is open goes
        // to Notification Centre only, with no banner over a screen that already shows it.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            // Identified by the model, so its session load and the Live Activity follower start
            // again on a new clinic. Never by language: `DirectionBridge` switches that in place.
            RootView()
                .id(ObjectIdentifier(host.model))
                .environment(host.model)
                .environment(host)
        }
    }
}
