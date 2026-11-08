import SwiftUI
import UserNotifications

@main
struct DawriApp: App {
    @State private var model = AppModel.launch()

    init() {
        // Set before the first notice can arrive. A notice that lands while the app is open goes
        // to Notification Centre only, with no banner over a screen that already shows it.
        UNUserNotificationCenter.current().delegate = NotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}
