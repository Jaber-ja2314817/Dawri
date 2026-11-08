import XCTest

/// One screen in one main state, reached by DEBUG launch arguments with the clinic frozen, so
/// nothing moves under the check. EverywhereTests and AccessibilityAuditTests both walk this
/// table, so a state added here is checked by both.
struct ScreenCase: CustomStringConvertible {
    enum Back {
        /// A stack root, or S06, which has no back of any kind.
        case none
        /// A pushed screen, whose one Back goes somewhere other than Home.
        case pushed
        /// A visit screen. One Back reaches Home, because a visit is a single entry above it.
        case home
    }

    let name: String
    let arguments: [String]
    /// The `screen-*` identifier.
    let screen: String
    let back: Back
    /// S06 has no navigation bar, so its title is its own heading.
    var isCover = false

    var description: String { name }
}

enum ScreenTable {
    private static let fatima = ["-demoPatient", "DEMO-10001", "-demoFreeze", "1"]
    private static let ahmed = ["-demoPatient", "DEMO-10002", "-demoFreeze", "1"]
    private static let ravi = ["-demoPatient", "DEMO-10003", "-demoFreeze", "1"]
    private static let frozen = ["-demoFreeze", "1"]

    static let all: [ScreenCase] = [
        ScreenCase(name: "s01", arguments: ["-demoScreen", "s01"], screen: "screen-welcome", back: .none),
        ScreenCase(name: "s02", arguments: ["-demoScreen", "s02"], screen: "screen-login", back: .pushed),
        ScreenCase(
            name: "s02-unknown-qid",
            arguments: ["-demoScreen", "s02", "-demoQid", "DEMO-99999", "-demoOtp", "0000", "-demoLogin", "form"],
            screen: "screen-login", back: .pushed),
        ScreenCase(
            name: "s03-no-visit", arguments: ["-demoScreen", "s03", "-demoPatient", "DEMO-10001", "-demoFresh", "1"],
            screen: "screen-home", back: .none),
        ScreenCase(name: "s03-active-visit", arguments: ["-demoScreen", "s03"] + fatima, screen: "screen-home", back: .none),
        ScreenCase(
            name: "s03-emergency-row", arguments: ["-demoScreen", "s03", "-demoStage", "emergency"] + ravi,
            screen: "screen-home", back: .none),
        ScreenCase(name: "s04", arguments: ["-demoScreen", "s04"] + fatima, screen: "screen-who", back: .pushed),
        ScreenCase(name: "consent", arguments: ["-demoScreen", "consent"] + fatima, screen: "screen-consent", back: .pushed),
        ScreenCase(
            name: "chat-opening", arguments: ["-demoScreen", "chat", "-demoChat", "opening"] + fatima,
            screen: "screen-chat", back: .home),
        ScreenCase(
            name: "chat-summary", arguments: ["-demoScreen", "chat", "-demoChat", "summary"] + fatima,
            screen: "screen-chat", back: .home),
        ScreenCase(
            name: "chat-error-retry",
            arguments: ["-demoScreen", "chat", "-demoChat", "opening", "-demoDraft", "@answer", "-demoChatAction", "send",
                        "-demoFail", "sendChat=network"] + fatima,
            screen: "screen-chat", back: .home),
        ScreenCase(
            name: "chat-listening", arguments: ["-demoScreen", "chat", "-demoChat", "midway", "-demoVoice", "listening"] + fatima,
            screen: "screen-chat", back: .home),
        ScreenCase(
            name: "chat-transcript-confirm",
            arguments: ["-demoScreen", "chat", "-demoChat", "midway", "-demoVoice", "confirm"] + fatima,
            screen: "screen-chat", back: .home),
        ScreenCase(name: "s06", arguments: ["-demoScreen", "s06"] + ravi, screen: "screen-emergency", back: .none, isCover: true),
        ScreenCase(
            name: "s06-self-harm", arguments: ["-demoScreen", "s06", "-demoPatch", "selfHarm"] + ravi,
            screen: "screen-emergency", back: .none, isCover: true),
        ScreenCase(
            name: "s06-red-flag-waiting", arguments: ["-demoScreen", "s06", "-demoRedFlag", "1", "-demoHold", "getVisit"] + ravi,
            screen: "screen-emergency", back: .none, isCover: true),
        ScreenCase(
            name: "s06-override-routed", arguments: ["-demoScreen", "s06", "-demoOverride", "1"] + ravi,
            screen: "screen-emergency", back: .none, isCover: true),
        ScreenCase(name: "s07", arguments: ["-demoScreen", "s07"] + ahmed, screen: "screen-refill", back: .home),
        ScreenCase(
            name: "s07-notice", arguments: ["-demoScreen", "s07", "-demoRefillAction", "message"] + ahmed,
            screen: "screen-refill", back: .home),
        ScreenCase(
            name: "s08-map", arguments: ["-demoScreen", "s08", "-demoView", "map"] + frozen, screen: "screen-centre", back: .home),
        ScreenCase(
            name: "s08-list", arguments: ["-demoScreen", "s08", "-demoView", "list"] + frozen, screen: "screen-centre",
            back: .home),
        ScreenCase(
            name: "s08-no-services", arguments: ["-demoScreen", "s08", "-demoPatch", "noCentres"] + frozen,
            screen: "screen-centre", back: .home),
        ScreenCase(name: "s09-reserved", arguments: ["-demoScreen", "s09"] + frozen, screen: "screen-reserved", back: .home),
        ScreenCase(
            name: "s09-expired", arguments: ["-demoScreen", "s09", "-demoStage", "expired"] + frozen, screen: "screen-reserved",
            back: .home),
        ScreenCase(name: "s10-triage", arguments: ["-demoScreen", "s10"] + frozen, screen: "screen-ticket", back: .home),
        ScreenCase(
            name: "s10-doctor", arguments: ["-demoScreen", "s10", "-demoStage", "doctor"] + frozen, screen: "screen-ticket",
            back: .home),
        ScreenCase(
            name: "s10-pharmacy", arguments: ["-demoScreen", "s10", "-demoStage", "pharmacy"] + frozen, screen: "screen-ticket",
            back: .home),
        ScreenCase(
            name: "s10-called", arguments: ["-demoScreen", "s10", "-demoTicket", "called"] + frozen, screen: "screen-ticket",
            back: .home),
        ScreenCase(
            name: "s10-serving", arguments: ["-demoScreen", "s10", "-demoTicket", "serving"] + frozen, screen: "screen-ticket",
            back: .home),
        ScreenCase(name: "s11", arguments: ["-demoScreen", "s11"] + frozen, screen: "screen-complete", back: .home),
        ScreenCase(
            name: "s11-rated", arguments: ["-demoScreen", "s11", "-demoRate", "5"] + frozen, screen: "screen-complete",
            back: .home),
        ScreenCase(
            name: "s12-rows", arguments: ["-demoScreen", "s12", "-demoHistory", "mixed"] + ahmed, screen: "screen-history",
            back: .pushed),
        ScreenCase(
            name: "s12-empty", arguments: ["-demoScreen", "s12", "-demoPatient", "DEMO-10001", "-demoFresh", "1"],
            screen: "screen-history", back: .pushed),
        ScreenCase(name: "settings", arguments: ["-demoScreen", "settings"], screen: "screen-settings", back: .pushed),
        ScreenCase(
            name: "settings-server", arguments: ["-demoScreen", "settings", "-demoMode", "server"], screen: "screen-settings",
            back: .pushed),
    ]
}
