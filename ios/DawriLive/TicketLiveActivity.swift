import ActivityKit
import DawriCore
import SwiftUI
import WidgetKit

/// The ticket's Live Activity, iOS Design section 9. The layouts are the `TicketLive…` views in
/// DawriCore, which the app's DEBUG gallery also renders, and the colours come from `DSPalette`
/// through `TicketLiveColors`. The app starts, updates and ends it locally: there is no push.
///
/// The extension does not know the in-app language, so every view reads the activity's own
/// `lang`. `context.isStale` is the system saying the stale date has passed with no update.
/// The AI line is left out, because nothing here is AI output.
struct TicketLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TicketActivityAttributes.self) { context in
            LockScreen(state: context.state, lang: context.attributes.lang, isStale: context.isStale)
        } dynamicIsland: { context in
            let state = context.state
            let lang = context.attributes.lang
            let stale = context.isStale
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TicketLiveExpandedLeading(state: state, lang: lang, isStale: stale)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TicketLiveExpandedTrailing(state: state, lang: lang, isStale: stale)
                }
                DynamicIslandExpandedRegion(.center) {
                    TicketLiveExpandedCenter(state: state, lang: lang, isStale: stale)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TicketLiveExpandedBottom(state: state, lang: lang, isStale: stale)
                }
            } compactLeading: {
                TicketLiveCompactLeading(state: state, lang: lang, isStale: stale)
            } compactTrailing: {
                TicketLiveCompactTrailing(state: state, lang: lang, isStale: stale)
            } minimal: {
                TicketLiveMinimal(state: state, lang: lang, isStale: stale)
            }
            // The Island is always black, so its keyline is the dark ink.
            .keylineTint(TicketLiveColors.island().ink)
        }
    }
}

/// The Lock Screen and banner, on an opaque surface that follows the phone's scheme.
private struct LockScreen: View {
    let state: TicketLiveState
    let lang: Lang
    let isStale: Bool

    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let colors = TicketLiveColors.lockScreen(scheme, contrast: contrast)
        TicketLiveLockScreen(state: state, lang: lang, isStale: isStale)
            .activityBackgroundTint(colors.surface)
            .activitySystemActionForegroundColor(colors.ink)
    }
}
