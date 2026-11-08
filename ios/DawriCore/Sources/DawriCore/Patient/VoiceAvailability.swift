import Foundation

/// The speech recognition permission, as `SFSpeechRecognizer.authorizationStatus()` gives it.
public enum SpeechPermission: Sendable, Equatable, CaseIterable {
    case notDetermined, denied, restricted, authorized
}

/// The microphone permission, as `AVAudioApplication.shared.recordPermission` gives it.
public enum MicPermission: Sendable, Equatable, CaseIterable {
    case undetermined, denied, granted
}

/// Everything the phone says about voice in one language, read without asking anything.
public struct VoiceConditions: Sendable, Equatable {
    public var speech: SpeechPermission
    public var mic: MicPermission
    /// `SFSpeechRecognizer(locale:)` gave a recogniser for the chosen locale.
    public var hasRecogniser: Bool
    /// That recogniser's `supportsOnDeviceRecognition`.
    public var supportsOnDevice: Bool
    /// That recogniser's `isAvailable`.
    public var isAvailable: Bool

    public init(
        speech: SpeechPermission, mic: MicPermission, hasRecogniser: Bool, supportsOnDevice: Bool,
        isAvailable: Bool
    ) {
        self.speech = speech
        self.mic = mic
        self.hasRecogniser = hasRecogniser
        self.supportsOnDevice = supportsOnDevice
        self.isAvailable = isAvailable
    }
}

/// What the phone's speech framework is to the voice gate: what it says, the one place it asks,
/// and the locales it has. The app's is `Speech` and `AVFAudio`. Tests use a fake.
public protocol SpeechPlatform: Sendable {
    /// The locale identifiers the recogniser supports, such as `ar-SA` or `en_US`.
    func supportedLocales() async -> Set<String>
    /// What the phone says now, for this locale, without asking anything.
    func conditions(locale: String) async -> VoiceConditions
    /// Asks for the microphone if it has not been asked. Only ever from the patient's mic tap.
    func requestMicrophone() async
    /// Asks for speech recognition if it has not been asked. Only ever from the patient's mic tap.
    func requestSpeech() async
}

/// Whether voice can run, decided from what the phone says. The rule this encodes: **recognition
/// is never requested unless it runs on this phone.** A recogniser that would need a server is
/// the same as no recogniser, and the patient types.
public enum VoiceAvailability {
    /// What to do next, from the phone's answers.
    public enum Verdict: Sendable, Equatable {
        /// Every permission is given and the recogniser runs on this phone, now.
        case ok
        /// A permission has not been asked yet. Ask, from the mic tap, and decide again.
        case ask
        /// Say so, and the patient types.
        case fail(VoiceFailure)
    }

    /// Arabic prefers Qatar's own locale, then its neighbours.
    public static let arabicPreference = ["ar-QA", "ar-SA", "ar-AE"]
    public static let englishPreference = ["en-US", "en-GB"]

    /// The order the checks run in:
    ///
    /// 1. A refused permission is `denied`, which the patient can change in Settings.
    /// 2. No recogniser for the language is `unsupported`.
    /// 3. A recogniser that cannot run on this phone is `unavailable`, before anything is asked,
    ///    so no prompt appears for voice that could never work.
    /// 4. A permission not yet asked is `ask`.
    /// 5. A recogniser that is not available now is `unavailable`.
    public static func verdict(_ phone: VoiceConditions) -> Verdict {
        if phone.mic == .denied || phone.speech == .denied || phone.speech == .restricted {
            return .fail(.denied)
        }
        if !phone.hasRecogniser { return .fail(.unsupported) }
        if !phone.supportsOnDevice { return .fail(.unavailable) }
        if phone.mic == .undetermined || phone.speech == .notDetermined { return .ask }
        if !phone.isAvailable { return .fail(.unavailable) }
        return .ok
    }

    /// True only when a recognition request may be made: everything is given and recognition
    /// runs on this phone.
    public static func mayRecognise(_ phone: VoiceConditions) -> Bool {
        verdict(phone) == .ok && phone.supportsOnDevice
    }

    /// The locale to listen in, from the ones the phone supports, or nil if it has none for this
    /// language. Arabic prefers `ar-QA`, `ar-SA`, `ar-AE`, then any Arabic. English prefers
    /// `en-US`, `en-GB`, then any English. `_` and `-` are read alike, and the answer uses `-`.
    public static func locale(for lang: Lang, supported: Set<String>) -> String? {
        let normal = Set(supported.map { $0.replacingOccurrences(of: "_", with: "-") })
        let preferred = lang == .ar ? arabicPreference : englishPreference
        let lowered = Dictionary(normal.map { ($0.lowercased(), $0) }, uniquingKeysWith: min)
        for wanted in preferred {
            if let found = lowered[wanted.lowercased()] { return found }
        }
        let prefix = lang.rawValue
        return normal.filter { id in
            let lower = id.lowercased()
            return lower == prefix || lower.hasPrefix(prefix + "-")
        }.min()
    }

    /// The mic tap, up to the moment a recognition request may be made: choose the locale, ask
    /// for what has not been asked (the microphone first, and speech only if the microphone was
    /// given), and decide. `recognise` is the only place a request is made, and it runs only
    /// when `mayRecognise` holds. Anything else throws a `VoiceFailure`.
    public static func open<Listening: Sendable>(
        _ lang: Lang, on platform: some SpeechPlatform,
        recognise: @Sendable (_ locale: String) async throws -> Listening
    ) async throws -> Listening {
        guard let locale = locale(for: lang, supported: await platform.supportedLocales()) else {
            throw VoiceFailure.unsupported
        }
        var phone = await platform.conditions(locale: locale)
        if verdict(phone) == .ask {
            if phone.mic == .undetermined {
                await platform.requestMicrophone()
                phone = await platform.conditions(locale: locale)
            }
            if phone.mic == .granted, phone.speech == .notDetermined {
                await platform.requestSpeech()
                phone = await platform.conditions(locale: locale)
            }
        }
        switch verdict(phone) {
        case .ok where mayRecognise(phone):
            return try await recognise(locale)
        case .fail(let failure):
            throw failure
        case .ok, .ask:
            // Still not answered: a prompt dismissed without a choice reads as refused.
            throw VoiceFailure.denied
        }
    }
}
