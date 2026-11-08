#if DEBUG
import DawriCore
import Foundation

/// The DEBUG launch hooks of S02, S03, S04, Consent, S12 and Settings, so a screenshot or a UI
/// test reaches each state with no tapping. Read through `DemoLaunch.current?.argument`, and all
/// of it compiles out of Release with the rest of `Debug/`.
///
///     -demoServer ok|refusedAi|unreachable, what Settings' probe answers. In Release the probe is
///       `NoServerProbe`, which always throws, so a Release build can never say Connected.
///       `-demoHold probe` keeps it waiting, and `debug-calls` counts it as `probe`.
///     -demoMode local|server  -demoAddress <text>  -demoConnect 1, Settings as if typed and tapped
///     -demoQid <text>  -demoOtp <text>  -demoLogin form|P001|P002|P003, S02 as if typed and tapped
///     -demoPick <patient id>, S04 opens Consent for that person, as a tap on the row would
///     -demoAgree 1, Consent taps I agree
///     -demoFresh 1, S03 and S12 start from a demo reset, so the patient has no visits
///     -demoResetPrompt 1, Settings opens the reset confirmation
@MainActor
enum DemoAccount {
    private static var used: Set<String> = []

    private static func argument(_ name: String) -> String? {
        DemoLaunch.current?.argument(name)
    }

    /// True the first time only, so a hook that acts on appear does not act again on Back.
    static func once(_ hook: String) -> Bool {
        used.insert(hook).inserted
    }

    // Settings

    /// The probe `-demoServer` asks for, or nil for the app's own.
    static var probe: (any ServerProbe)? {
        switch argument("demoServer") {
        case "ok": DemoProbe(aiMode: "simulated")
        case "refusedAi": DemoProbe(aiMode: "real")
        case "unreachable": DemoProbe(aiMode: nil)
        default: nil
        }
    }

    static var mode: String? { argument("demoMode") }
    static var address: String? { argument("demoAddress") }
    static var connects: Bool { argument("demoConnect") == "1" }
    static var opensResetPrompt: Bool { argument("demoResetPrompt") == "1" }

    // S02

    static var qid: String? { argument("demoQid") }
    static var otp: String? { argument("demoOtp") }
    /// `form` for the Log in button, or a chip's patient id.
    static var loginTap: String? { argument("demoLogin") }

    // S04 and Consent

    static var pick: String? { argument("demoPick") }
    static var agrees: Bool { argument("demoAgree") == "1" }

    // S03 and S12

    /// A patient with no visits: the real reset, once, before the first list is read.
    static func freshClinic(_ model: AppModel) async {
        guard argument("demoFresh") == "1", once("fresh") else { return }
        try? await model.demoDriver?.resetDemo()
    }
}

/// Answers as a clinic server's `/api/health` would, through the proxy's fault gate, so a held
/// probe shows Connecting and every call is counted.
private struct DemoProbe: ServerProbe {
    /// Nil throws, as an unreachable server does.
    let aiMode: String?

    func probe(url: URL) async throws -> Health {
        try await DemoLaunch.current?.faults.gate("probe")
        guard let aiMode else { throw PhoneFeatureError.unavailable }
        let body = #"{"status":"ok","ai_mode":"\#(aiMode)","simulate_load":true}"#
        return try JSONDecoder().decode(Health.self, from: Data(body.utf8))
    }
}
#endif
