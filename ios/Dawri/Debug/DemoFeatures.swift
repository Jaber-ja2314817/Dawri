#if DEBUG
import DawriCore
import SwiftUI

/// The phone features a DEBUG launch gets. Everything is the phone's own, as in a normal launch,
/// with two exceptions, so a launch hook never puts a system prompt in front of a screen or a
/// UI test that did not ask for one:
///
///     -demoNotify on, the real local notifications. Without it there are none, and so no
///       notification permission prompt
///     -demoLive off, no Live Activity
///     -demoLiveProbe 1, adds `live-probe`, whose value lists the running activities and the
///       pending notices, for LiveActivityTests and NotificationTests
extension DemoLaunch {
    var features: PhoneFeatures {
        var features = PhoneFeatures.device
        if argument("demoNotify") != "on" {
            features.notifier = NoVisitNotifier()
        }
        if argument("demoLive") == "off" {
            features.live = NoTicketLive()
        }
        return features
    }

    var showsLiveProbe: Bool { argument("demoLiveProbe") == "1" }
}

/// `-demoLiveProbe 1`: one small element, `live-probe`, whose value is
///
///     activities=<visit>,<number|->,<stage>,<ticket state|->,<lang>,<ahead|->;...
///     | pending=<id>@<seconds to fire>@<key>;...
///     | auth=<notification permission, or none without -demoNotify on>
///     | followed=<the newest live visit, or ->
///     | plan=<index>:<kind>:<stage>@<seconds to due, or done>;...
///
/// read twice a second. Activities are the ones still showing, so an ended one is gone from it.
/// The plan is the demo clinic's for the followed visit. It reads only; nothing here moves a
/// visit, though reading the plan runs the demo steps already due, as any read does.
struct LiveProbe: View {
    @Environment(AppModel.self) private var model
    @State private var value = ""

    var body: some View {
        Text(verbatim: value)
            .font(.system(size: 7))
            .foregroundStyle(DS.Color.muted)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .allowsHitTesting(false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: "live-probe"))
            .accessibilityValue(Text(verbatim: value))
            .accessibilityIdentifier("live-probe")
            .task {
                while !Task.isCancelled {
                    value = await model.liveTicket.probe()
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
    }
}

/// Puts the probe at the top edge when the launch asks for it. Over everything, and passing
/// every touch through, so it changes no layout and blocks no tap.
struct LiveProbeModifier: ViewModifier {
    func body(content: Content) -> some View {
        // In the status bar's band, above anything a test taps.
        content.overlay(alignment: .top) {
            if DemoLaunch.current?.showsLiveProbe == true {
                LiveProbe()
                    .padding(.horizontal, DS.Space.s)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .ignoresSafeArea()
            }
        }
    }
}
#endif
