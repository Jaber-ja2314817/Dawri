import DawriCore
import SwiftUI

/// Settings. Which language and which clinic? A phone-only screen, pushed from S01 and S03.
/// Sections are cards with a heading above, not a `Form`, so the shape holds on every system
/// and the footer stays.
///
/// In this phase the app stays on the clinic on this phone whatever the mode says. Clinic server
/// mode only stores an address and checks it. The address passes `ServerAddress` first, so a
/// refused host never reaches the probe, and the probe must then answer `ai_mode` simulated. In
/// Release the probe is `NoServerProbe`, which always throws, so nothing can say Connected.
struct SettingsScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsContent(model: model)
    }
}

/// The two modes of iOS Brief, as saved.
private enum ClinicMode: String, CaseIterable {
    case local, server
}

private enum Connection: Equatable {
    case idle, connecting, connected, refusedHost, refusedAi, unreachable

    var errorKey: String? {
        switch self {
        case .refusedHost: "settings.server.refusedHost"
        case .refusedAi: "settings.server.refusedAi"
        case .unreachable: "settings.server.unreachable"
        default: nil
        }
    }
}

private struct SettingsContent: View {
    private static let modeKey = "dawri.mode"
    private static let serverKey = "dawri.server"
    /// A local address of the kind the README's server runs on. Never a hosted one.
    private static let sample = "http://192.168.1.20:8100"

    let model: AppModel

    @Environment(\.lang) private var lang
    @State private var mode: ClinicMode
    @State private var address: String
    @State private var connection = Connection.idle
    /// Bumped by each connect, so an answer to an older one is dropped.
    @State private var attempt = 0
    @State private var showsResetConfirm = false
    @State private var isResetting = false
    @State private var resetError: (any Error)?

    init(model: AppModel) {
        self.model = model
        let savedMode = model.settings.read(Self.modeKey).flatMap(ClinicMode.init(rawValue:))
        let savedAddress = model.settings.read(Self.serverKey)
        _mode = State(initialValue: Self.demoMode ?? savedMode ?? .local)
        _address = State(initialValue: Self.demoAddress ?? savedAddress ?? "")
    }

    /// `-demoMode` and `-demoAddress`, which DEBUG launches use in place of what is saved.
    private static var demoMode: ClinicMode? {
        #if DEBUG
        DemoAccount.mode.flatMap(ClinicMode.init(rawValue:))
        #else
        nil
        #endif
    }

    private static var demoAddress: String? {
        #if DEBUG
        DemoAccount.address
        #else
        nil
        #endif
    }

    /// The app's probe, or in DEBUG the one `-demoServer` asks for.
    private var probe: any ServerProbe {
        #if DEBUG
        if let demo = DemoAccount.probe { return demo }
        #endif
        return model.features.probe
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
            model.settings.write(next.rawValue, for: Self.modeKey)
            attempt += 1
            connection = .idle
        }
        .onChange(of: address) {
            attempt += 1
            connection = .idle
        }
        .sensoryFeedback(DS.Haptic.select, trigger: mode)
        #if DEBUG
        .task {
            if DemoAccount.connects, DemoAccount.once("connect") { await connect() }
            if DemoAccount.opensResetPrompt, DemoAccount.once("resetPrompt") { showsResetConfirm = true }
        }
        #endif
    }

    // Language

    private var languageSection: some View {
        section(lang.t("settings.language")) {
            Picker(
                selection: Binding(get: { lang }, set: { model.switchLanguage(to: $0) })
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
                    error: connection.errorKey.map { lang.t($0) }, kind: .address,
                    placeholder: Self.sample, identifier: "settings-server")
                    .submitLabel(.go)
                    .onSubmit { Task { await connect() } }
                if connection == .connected {
                    Pill(lang.t("settings.server.ok"), tone: .positive)
                        .accessibilityIdentifier("settings-server-ok")
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

    /// The guard, then `/api/health` only. Nothing else is read, and the app does not switch.
    private func connect() async {
        guard connection != .connecting else { return }
        model.settings.write(address, for: Self.serverKey)
        attempt += 1
        let mine = attempt
        // Before any request: a refused host never reaches the probe.
        guard let url = ServerAddress.parse(address).url else {
            connection = .refusedHost
            return
        }
        connection = .connecting
        let next: Connection
        do {
            let health = try await probe.probe(url: url)
            next = health.aiMode == .simulated ? .connected : .refusedAi
        } catch {
            next = .unreachable
        }
        guard mine == attempt else { return }
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
