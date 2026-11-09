import DawriCore
import SwiftUI

/// Settings. Which language and which clinic? A phone-only screen, pushed from S01 and S03.
/// Sections are cards with a heading above, not a `Form`, so the shape holds on every system
/// and the footer stays.
///
/// Choosing a clinic:
/// - **Clinic server** shows the address field. Connect runs `ServerAddress` first, so a refused
///   host never reaches the probe, then the probe reads `/api/health` only, and only
///   `ai_mode: simulated` passes. Then the host saves the choice, ends the old clinic's Live
///   Activity and notices, and moves the app to that server, signed out, still on Settings.
/// - **On this phone** moves back at once, with this phone's own saved session.
/// - A refused host, a refused mode or an unreachable server leaves the app on its current
///   clinic.
///
/// Reset exists only on this phone, because only the demo clinic conforms to `DemoDriving`.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(AppHost.self) private var host

    var body: some View {
        SettingsContent(model: model, host: host)
    }
}

/// The two modes of iOS Brief.
private enum ClinicMode: String, CaseIterable {
    case local, server
}

private enum Connection: Equatable {
    case idle, connecting, connected, refusedHost, refusedAddress, refusedAi, unreachable

    var errorKey: String? {
        switch self {
        case .refusedHost: "settings.server.refusedHost"
        case .refusedAddress: "settings.server.refusedAddress"
        case .refusedAi: "settings.server.refusedAi"
        case .unreachable: "settings.server.unreachable"
        default: nil
        }
    }

    /// What a refusal of the typed address shows. Only a Hugging Face host is the host refusal.
    init(_ refusal: ServerAddress.Refusal) {
        self = refusal == .forbiddenHost ? .refusedHost : .refusedAddress
    }
}

private struct SettingsContent: View {
    /// A local address of the kind the README's server runs on. Never a hosted one.
    private static let sample = "http://192.168.1.20:8100"

    let model: AppModel
    let host: AppHost

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var mode: ClinicMode
    @State private var address: String
    @State private var connection = Connection.idle
    /// Bumped by each connect and each change, so an answer to an older one is dropped.
    @State private var attempt = 0
    @State private var showsResetConfirm = false
    @State private var isResetting = false
    /// Each language picked here, for the picker's `.select` haptic. A switch from the toggle has none.
    @State private var languagePicks = 0
    @State private var resetError: (any Error)?

    init(model: AppModel, host: AppHost) {
        self.model = model
        self.host = host
        let inUse = model.clinic.serverURL
        let shown: ClinicMode = inUse != nil || Self.demoMode == .server ? .server : .local
        _mode = State(initialValue: shown)
        _address = State(
            initialValue: inUse?.absoluteString ?? Self.demoAddress
                ?? model.settings.read(AppHost.serverKey) ?? "")
    }

    /// `-demoMode`, which DEBUG launches use as if the picker had been set, on the first Settings.
    private static var demoMode: ClinicMode? {
        #if DEBUG
        DemoAccount.firstMode.flatMap(ClinicMode.init(rawValue:))
        #else
        nil
        #endif
    }

    /// `-demoAddress`, as if typed.
    private static var demoAddress: String? {
        #if DEBUG
        DemoAccount.address
        #else
        nil
        #endif
    }

    /// The app's probe, or in DEBUG the fake one `-demoServer` asks for.
    private var probe: any ServerProbe {
        #if DEBUG
        if let demo = DemoAccount.probe { return demo }
        #endif
        return model.features.probe
    }

    /// The server the app is using now, if any.
    private var inUse: URL? { model.clinic.serverURL }

    /// The pill: a connect that just passed, or the server in use, while its health says
    /// simulated.
    private var showsConnected: Bool {
        switch connection {
        case .connected: true
        case .idle: inUse != nil && model.health?.aiMode == .simulated && !model.healthRefused
        default: false
        }
    }

    /// The connect's own refusal, or the server in use refusing after a relaunch.
    private var errorKey: String? {
        if let key = connection.errorKey { return key }
        if connection == .idle, inUse != nil, model.healthRefused { return "settings.server.refusedAi" }
        return nil
    }

    var body: some View {
        PatientScaffold(title: lang.t("settings.title")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                languageSection
                modeSection
                demoSection
                    .padding(.top, DS.Space.s)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-settings")
        }
        .onChange(of: mode) { _, next in
            attempt += 1
            connection = .idle
            // Back to this phone at once. Choosing Clinic server only shows the field: nothing
            // changes until Connect passes both guards.
            if next == .local, inUse != nil {
                Task { await host.useLocal() }
            }
        }
        .onChange(of: address) {
            attempt += 1
            connection = .idle
        }
        .sensoryFeedback(DS.Haptic.select, trigger: mode)
        .sensoryFeedback(DS.Haptic.select, trigger: languagePicks)
        #if DEBUG
        .task {
            if DemoAccount.connects, DemoAccount.once("connect") { await connect() }
            if DemoAccount.opensResetPrompt, DemoAccount.once("resetPrompt") { showsResetConfirm = true }
            // `-demoMode local` on a server launch: the picker's tap back to this phone.
            if DemoAccount.mode == ClinicMode.local.rawValue, inUse != nil, DemoAccount.once("useLocal") {
                mode = .local
            }
        }
        #endif
    }

    // Language

    private var languageSection: some View {
        section(lang.t("settings.language")) {
            Picker(
                selection: Binding(get: { lang }, set: {
                    languagePicks += 1
                    model.switchLanguage(to: $0)
                })
            ) {
                // Each language in its own script, as the toggle shows it.
                Text(verbatim: "العربية").tag(Lang.ar)
                Text(verbatim: "English").tag(Lang.en)
            } label: {
                Text(verbatim: lang.t("settings.language"))
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("settings-language")
        }
    }

    // Mode and server

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            section(lang.t("settings.mode")) {
                Picker(selection: $mode) {
                    Text(verbatim: lang.t("settings.mode.local")).tag(ClinicMode.local)
                    Text(verbatim: lang.t("settings.mode.server")).tag(ClinicMode.server)
                } label: {
                    Text(verbatim: lang.t("settings.mode"))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityIdentifier("settings-mode")
            }
            if mode == .server {
                serverCard
                Notice(lang.t("settings.server.limit"))
                    .accessibilityIdentifier("settings-server-limit")
            }
        }
    }

    private var serverCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                DSTextField(
                    label: lang.t("settings.server"), text: $address,
                    error: errorKey.map { lang.t($0) }, kind: .address,
                    placeholder: Self.sample, identifier: "settings-server")
                    .submitLabel(.go)
                    .onSubmit { Task { await connect() } }
                if showsConnected {
                    connectedPill
                        .accessibilityIdentifier("settings-server-ok")
                }
                if let inUse {
                    inUseLine(inUse.absoluteString)
                }
                Button(lang.t("settings.connect")) {
                    Task { await connect() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .dsLoading(connection == .connecting)
                .disabled(address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("settings-connect")
            }
        }
    }

    /// `Pill` never wraps, which at accessibility sizes would push the card off the screen. There
    /// the same colours take a rounded box that wraps (iOS Design section 3.4).
    @ViewBuilder
    private var connectedPill: some View {
        if typeSize.isAccessibilitySize {
            Text(verbatim: lang.t("settings.server.ok"))
                .dsText(.pill)
                .foregroundStyle(DS.Color.pillPositiveText)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, DS.Space.xs)
                .padding(.horizontal, DS.Space.s)
                .background(
                    DS.Color.pillPositiveFill,
                    in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
        } else {
            Pill(lang.t("settings.server.ok"), tone: .positive)
        }
    }

    /// Whenever the app is using a server: the sentence, then the address on a line of its own,
    /// left to right in both languages, so a URL is never broken inside a sentence.
    private func inUseLine(_ address: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(verbatim: lang.t("settings.server.inUse"))
                .dsText(.secondary)
                .foregroundStyle(DS.Color.ink)
            Text(verbatim: Bidi.ltr(address))
                .dsText(.secondaryStrong)
                .foregroundStyle(DS.Color.ink)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(lang.t("settings.server.inUse")) \(address)"))
        .accessibilityIdentifier("settings-server-in-use")
    }

    /// The address guard, then `/api/health` only. Only a pass moves the app to the server.
    private func connect() async {
        guard connection != .connecting else { return }
        attempt += 1
        let mine = attempt
        // Before any request: a refused host never reaches the probe.
        let url: URL
        switch ServerAddress.parse(address) {
        case .refused(.empty):
            return
        case .refused(let refusal):
            connection = Connection(refusal)
            return
        case .ok(let parsed):
            url = parsed
        }
        connection = .connecting
        var next: Connection
        do {
            let health = try await probe.probe(url: url)
            next = health.aiMode == .simulated ? .connected : .refusedAi
        } catch ServerCheck.Refusal.notSimulated {
            next = .refusedAi
        } catch ServerCheck.Refusal.address(let refusal) {
            next = Connection(refusal)
        } catch {
            next = .unreachable
        }
        guard mine == attempt, mode == .server else { return }
        if next == .connected {
            do {
                try host.useServer(url)
            } catch ServerCheck.Refusal.address(let refusal) {
                next = Connection(refusal)
            } catch {
                next = .unreachable
            }
        }
        connection = next
    }

    // Demo

    private var demoSection: some View {
        section(lang.t("settings.demo")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                // Only the clinic on this phone has demo data to reset. A clinic server does not
                // conform to `DemoDriving`, so the button cannot reach one.
                if mode == .local, model.demoDriver != nil {
                    Button(lang.t("settings.reset")) {
                        showsResetConfirm = true
                    }
                    .buttonStyle(DestructiveButtonStyle())
                    .dsLoading(isResetting)
                    .accessibilityIdentifier("settings-reset")
                    .confirmationDialog(
                        lang.t("settings.reset"), isPresented: $showsResetConfirm, titleVisibility: .visible
                    ) {
                        Button(lang.t("settings.reset"), role: .destructive) {
                            Task { await reset() }
                        }
                        Button(lang.t("common.cancel"), role: .cancel) {}
                    } message: {
                        Text(verbatim: lang.t("settings.resetConfirm"))
                    }
                    if let resetError {
                        ErrorBlock(message: errorText(resetError, strings: .bundled, lang: lang)) {
                            Task { await reset() }
                        }
                    }
                }
                // On this phone the demo clinic's steps are known ahead, so the reminders are set
                // ahead and need no network. Clinic server mode says its own limit above.
                if mode == .local {
                    Text(verbatim: lang.t("settings.notifyLocal"))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.muted)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings-notify-local")
                }
                Text(verbatim: lang.t("settings.notReviewed"))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.muted)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("settings-not-reviewed")
            }
        }
    }

    /// Back to a fresh demo. The patient stays signed in. S03 reads its visits again on every
    /// appear, so going back shows the reset, and the record is read again here.
    private func reset() async {
        guard !isResetting, let driver = model.demoDriver else { return }
        isResetting = true
        resetError = nil
        do {
            try await driver.resetDemo()
            // The visits are gone, so their Live Activity and reminders go too.
            model.liveTicket.endAll()
            if model.isSignedIn { await model.reloadMe() }
        } catch {
            if !model.sessionEnded(by: error) { resetError = error }
        }
        isResetting = false
    }

    // Layout

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeading(title)
            Card {
                content()
            }
        }
    }
}
