import DawriCore
import MapKit
import SwiftUI

/// What the root cover shows: S06 behind its gate. Everything that must happen once belongs
/// here, above the gate, so the visit landing cannot repeat it.
struct EmergencyCoverScreen: View {
    let cover: EmergencyCover

    @Environment(AppModel.self) private var model

    var body: some View {
        VisitGate(model: model, id: cover.visitId, screen: .emergency, redFlag: cover.redFlag) {
            visit, watcher in
            EmergencyScreen(visit: visit, watcher: watcher)
        }
        // White status bar text. The tokens here do not depend on the scheme.
        .preferredColorScheme(.dark)
        .accessibilityAddTraits(.isModal)
        .onAppear { DS.Haptic.emergency() }
    }
}

/// S06. What do I do right now? Call 999. The port of frontend/src/pages/patient/Emergency.tsx,
/// with Call 999 pinned, so it can never scroll away. Never a number or a queue figure.
struct EmergencyScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @State private var route: OverrideResponse?
    @State private var isOverriding = false
    @State private var error: (any Error)?

    private var card: EmergencyCard? { visit.emergency }

    private var reply: String {
        (lang == .ar ? card?.replyAr : card?.replyEn) ?? card?.reply ?? lang.t("emergency.title")
    }

    var body: some View {
        PatientScaffold(title: lang.t("emergency.title"), tone: .emergency) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Text(verbatim: Bidi.auto(reply))
                    .dsText(card?.selfHarm == true ? .urgent : .body)
                    .foregroundStyle(DS.Emergency.text)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel(Text(verbatim: reply))
                    .accessibilityIdentifier("emergency-reply")
                if let place = card?.nearestEd {
                    NearestDepartmentCard(place: place)
                }
                if let error {
                    EmergencyErrorBlock(message: errorText(error, strings: .bundled, lang: lang)) {
                        Task { await override() }
                    }
                }
                if let route {
                    routeBlock(route)
                } else {
                    overrideButton
                }
            }
        } pinnedBottom: {
            EmergencyCallButton()
        }
        .accessibilityIdentifier("screen-emergency")
        #if DEBUG
        .task {
            if DemoLaunch.current?.argument("demoOverride") == "1" { await override() }
        }
        #endif
    }

    private var overrideButton: some View {
        Button(lang.t("emergency.override")) {
            Task { await override() }
        }
        .buttonStyle(QuietButtonStyle(tone: .emergency))
        // The spinner without `.disabled`: the style greys a disabled label to `muted`, which
        // fails contrast on the field. `override` ignores a second tap while one is out.
        .environment(\.dsIsLoading, isOverriding)
        .accessibilityValue(isOverriding ? Text(verbatim: lang.t("common.loading")) : Text(verbatim: ""))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityIdentifier("emergency-override")
    }

    /// The override logs and gives no ticket, so all that comes back is where to go.
    private func routeBlock(_ route: OverrideResponse) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            let message = lang == .ar ? route.messageAr : route.message
            Text(verbatim: Bidi.auto(message))
                .dsText(.bodyStrong)
                .foregroundStyle(DS.Emergency.text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel(Text(verbatim: message))
                .accessibilityIdentifier("emergency-route")
            Button(lang.t("emergency.home")) {
                model.dismissEmergency()
            }
            .buttonStyle(QuietButtonStyle(underlined: true, tone: .emergency))
            .accessibilityIdentifier("emergency-home")
        }
    }

    private func override() async {
        guard !isOverriding else { return }
        isOverriding = true
        error = nil
        defer { isOverriding = false }
        do {
            route = try await model.service.emergencyOverride(visitId: visit.visitId)
        } catch {
            if model.sessionEnded(by: error) { return }
            if (error as? ClinicError)?.code == "not_emergency" { await watcher.refetch() }
            self.error = error
        }
    }
}

/// S06 before the visit is read. Call 999 is here from the first frame. After a red flag the
/// title is too, and the only thing a failed load costs is the department card. On the way in
/// from a Home row a failed load leaves the same way the web's Back does, through S03, because
/// the cover has no back.
struct EmergencyPending: View {
    let redFlag: Bool
    let failure: (any Error)?
    let retry: () -> Void

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang

    var body: some View {
        PatientScaffold(title: lang.t(redFlag ? "emergency.title" : "screen.emergency"), tone: .emergency) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let failure {
                    EmergencyErrorBlock(
                        message: errorText(failure, strings: .bundled, lang: lang), retry: retry)
                    if !redFlag {
                        Button(lang.t("emergency.home")) {
                            model.dismissEmergency()
                        }
                        .buttonStyle(QuietButtonStyle(underlined: true, tone: .emergency))
                        .accessibilityIdentifier("emergency-home")
                    }
                } else if !redFlag {
                    bars
                }
            }
        } pinnedBottom: {
            EmergencyCallButton()
        }
        .accessibilityIdentifier("screen-emergency")
    }

    /// Tone on tone: `skeleton` is a surface token, and this is the field.
    private var bars: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            shape.fill(DS.Emergency.pressed).frame(height: 44)
            shape.fill(DS.Emergency.pressed).frame(height: 112)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: lang.t("common.loading")))
        .accessibilityIdentifier("visit-loading")
    }
}

/// The part of S06 that needs nothing from anywhere. The action is the tap and nothing else: no
/// `await`, no haptic and no dialog of ours. It lands VoiceOver here on arrival.
private struct EmergencyCallButton: View {
    private static let number = URL(string: "tel://999")!  // A literal that always parses.

    @Environment(\.openURL) private var openURL
    @Environment(\.lang) private var lang
    @AccessibilityFocusState private var isFocused: Bool

    var body: some View {
        Button {
            openURL(Self.number)
        } label: {
            Label {
                Text(verbatim: lang.t("emergency.call"))
            } icon: {
                Image(systemName: "phone.fill")
            }
        }
        .buttonStyle(EmergencyCallButtonStyle())
        .accessibilityFocused($isFocused)
        .accessibilityIdentifier("emergency-call")
        .padding(.horizontal, DS.Space.l)
        .padding(.top, DS.Space.m)
        .onAppear { isFocused = true }
    }
}

/// The white card on the field, with the map link. No queue figure: a distance and a place.
private struct NearestDepartmentCard: View {
    let place: NearestEd

    @Environment(\.lang) private var lang
    #if DEBUG
    @Environment(\.openURL) private var openURL
    #endif

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(verbatim: lang.t("emergency.nearest"))
                .dsText(.secondary)
                .foregroundStyle(DS.Emergency.cardMuted)
            Text(verbatim: Bidi.auto(centreName(place, lang: lang)))
                .dsText(.section)
                .foregroundStyle(DS.Emergency.cardText)
                .accessibilityLabel(Text(verbatim: centreName(place, lang: lang)))
            Text(verbatim: distance)
                .dsText(.secondary)
                .foregroundStyle(DS.Emergency.cardText)
                .accessibilityLabel(Text(verbatim: Bidi.strip(distance)))
                .accessibilityIdentifier("emergency-distance")
            Button(action: openMap) {
                Label {
                    Text(verbatim: lang.t("emergency.map"))
                        .underline()
                } icon: {
                    Image(systemName: "mappin")
                }
                .dsText(.label)
                .foregroundStyle(DS.Emergency.link)
                .multilineTextAlignment(.leading)
                .frame(minHeight: DS.Size.minTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("emergency-map")
        }
        .multilineTextAlignment(.leading)
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Emergency.card, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emergency-nearest")
    }

    private var distance: String {
        let km = place.distanceKm
        let figure = km == km.rounded() ? String(Int(km)) : String(km)
        return Bidi.fill("emergency.distance", ["km": figure], lang: lang)
    }

    private func openMap() {
        #if DEBUG
        if DemoLaunch.current?.recordsLinks == true, let url = URL(string: "maps://?ll=\(place.lat),\(place.lng)") {
            openURL(url)
            return
        }
        #endif
        let point = CLLocationCoordinate2D(latitude: place.lat, longitude: place.lng)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: point))
        item.name = centreName(place, lang: lang)
        item.openInMaps()
    }
}

/// `ErrorBlock` on the field, so it uses the card tokens and not the theme's surface.
struct EmergencyErrorBlock: View {
    let message: String
    let retry: () -> Void

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous)
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.m))
        layout {
            Text(verbatim: message)
                .dsText(.secondary)
                .foregroundStyle(DS.Emergency.cardText)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(lang.t("common.retry"), action: retry)
                .buttonStyle(EmergencyRetryStyle())
                .accessibilityIdentifier("emergency-retry")
        }
        .padding(.vertical, DS.Space.m)
        .padding(.horizontal, DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.Emergency.card, in: shape)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("emergency-error")
        .onAppear {
            AccessibilityNotification.Announcement(message).post()
        }
    }
}

/// The quiet retry, in card text. `QuietButtonStyle` only knows ink and the field's white.
private struct EmergencyRetryStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsText(.label)
            .underline()
            .foregroundStyle(DS.Emergency.cardText)
            .frame(minWidth: DS.Size.minTarget, minHeight: DS.Size.minTarget)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .animation(
                DS.Motion.resolved(
                    configuration.isPressed ? DS.Motion.press : DS.Motion.release,
                    reduceMotion: reduceMotion),
                value: configuration.isPressed)
    }
}
