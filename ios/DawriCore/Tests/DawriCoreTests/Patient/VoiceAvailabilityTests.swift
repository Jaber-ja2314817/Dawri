import Foundation
import Synchronization
import Testing
@testable import DawriCore

/// A phone whose answers the test sets, and which records every prompt.
private final class FakeSpeechPlatform: SpeechPlatform {
    struct State {
        var phone: VoiceConditions
        var locales: Set<String>
        var micAnswer: MicPermission
        var speechAnswer: SpeechPermission
        var asked: [String] = []
        var conditionLocales: [String] = []
    }

    let state: Mutex<State>

    init(
        _ phone: VoiceConditions, locales: Set<String> = ["ar-SA", "en-US"],
        micAnswer: MicPermission = .granted, speechAnswer: SpeechPermission = .authorized
    ) {
        state = Mutex(State(
            phone: phone, locales: locales, micAnswer: micAnswer, speechAnswer: speechAnswer))
    }

    var asked: [String] { state.withLock { $0.asked } }
    var conditionLocales: [String] { state.withLock { $0.conditionLocales } }

    func supportedLocales() async -> Set<String> { state.withLock { $0.locales } }

    func conditions(locale: String) async -> VoiceConditions {
        state.withLock {
            $0.conditionLocales.append(locale)
            return $0.phone
        }
    }

    func requestMicrophone() async {
        state.withLock {
            $0.asked.append("mic")
            $0.phone.mic = $0.micAnswer
        }
    }

    func requestSpeech() async {
        state.withLock {
            $0.asked.append("speech")
            $0.phone.speech = $0.speechAnswer
        }
    }
}

/// Counts recognition requests, which must only happen on device.
private final class Requests: Sendable {
    private let made = Mutex<[String]>([])
    var locales: [String] { made.withLock { $0 } }

    func make(_ locale: String) -> String {
        made.withLock { $0.append(locale) }
        return "listening in \(locale)"
    }
}

private func phone(
    speech: SpeechPermission = .authorized, mic: MicPermission = .granted,
    recogniser: Bool = true, onDevice: Bool = true, available: Bool = true
) -> VoiceConditions {
    VoiceConditions(
        speech: speech, mic: mic, hasRecogniser: recogniser, supportsOnDevice: onDevice,
        isAvailable: available)
}

private func failure(of work: () async throws -> String) async -> VoiceFailure? {
    do {
        _ = try await work()
        return nil
    } catch {
        return error as? VoiceFailure
    }
}

@Suite("S05 voice availability: recognition runs on this phone or not at all")
struct VoiceAvailabilityVerdictTests {
    @Test func `everything given and on device is ok`() {
        #expect(VoiceAvailability.verdict(phone()) == .ok)
        #expect(VoiceAvailability.mayRecognise(phone()))
    }

    @Test(arguments: [
        phone(mic: .denied), phone(speech: .denied), phone(speech: .restricted),
        phone(speech: .denied, mic: .undetermined), phone(mic: .denied, onDevice: false),
        phone(speech: .restricted, recogniser: false),
    ])
    func `a refused permission is denied, before anything else`(conditions: VoiceConditions) {
        #expect(VoiceAvailability.verdict(conditions) == .fail(.denied))
        #expect(!VoiceAvailability.mayRecognise(conditions))
    }

    @Test func `no recogniser for the language is unsupported`() {
        #expect(VoiceAvailability.verdict(phone(recogniser: false)) == .fail(.unsupported))
        #expect(
            VoiceAvailability.verdict(phone(speech: .notDetermined, recogniser: false))
                == .fail(.unsupported))
    }

    @Test func `a recogniser that needs a server is unavailable, even before asking`() {
        #expect(VoiceAvailability.verdict(phone(onDevice: false)) == .fail(.unavailable))
        #expect(
            VoiceAvailability.verdict(phone(speech: .notDetermined, mic: .undetermined, onDevice: false))
                == .fail(.unavailable))
        #expect(!VoiceAvailability.mayRecognise(phone(onDevice: false)))
    }

    @Test(arguments: [
        phone(mic: .undetermined), phone(speech: .notDetermined),
        phone(speech: .notDetermined, mic: .undetermined),
        phone(speech: .notDetermined, available: false),
    ])
    func `a permission not asked yet is ask`(conditions: VoiceConditions) {
        #expect(VoiceAvailability.verdict(conditions) == .ask)
        #expect(!VoiceAvailability.mayRecognise(conditions))
    }

    @Test func `a recogniser not available now is unavailable`() {
        #expect(VoiceAvailability.verdict(phone(available: false)) == .fail(.unavailable))
    }

    @Test func `recognition is never allowed off device, whatever else is true`() {
        for speech in SpeechPermission.allCases {
            for mic in MicPermission.allCases {
                for recogniser in [false, true] {
                    for available in [false, true] {
                        let conditions = phone(
                            speech: speech, mic: mic, recogniser: recogniser, onDevice: false,
                            available: available)
                        #expect(!VoiceAvailability.mayRecognise(conditions))
                        #expect(VoiceAvailability.verdict(conditions) != .ok)
                    }
                }
            }
        }
    }
}

@Suite("S05 voice locale: Qatar first, then the neighbours, then any")
struct VoiceLocaleTests {
    @Test func `Arabic prefers ar-QA, ar-SA, ar-AE, then any Arabic`() {
        let all: Set = ["ar-AE", "ar-SA", "ar-QA", "ar-EG", "en-US"]
        #expect(VoiceAvailability.locale(for: .ar, supported: all) == "ar-QA")
        #expect(VoiceAvailability.locale(for: .ar, supported: all.subtracting(["ar-QA"])) == "ar-SA")
        #expect(VoiceAvailability.locale(for: .ar, supported: ["ar-AE", "ar-EG"]) == "ar-AE")
        #expect(VoiceAvailability.locale(for: .ar, supported: ["ar-KW", "ar-EG", "en-US"]) == "ar-EG")
        #expect(VoiceAvailability.locale(for: .ar, supported: ["ar"]) == "ar")
    }

    @Test func `English prefers en-US, en-GB, then any English`() {
        #expect(VoiceAvailability.locale(for: .en, supported: ["en-GB", "en-US", "ar-SA"]) == "en-US")
        #expect(VoiceAvailability.locale(for: .en, supported: ["en-GB", "en-AU"]) == "en-GB")
        #expect(VoiceAvailability.locale(for: .en, supported: ["en-IN", "en-AU"]) == "en-AU")
    }

    @Test func `underscores read as dashes, and case does not matter`() {
        #expect(VoiceAvailability.locale(for: .ar, supported: ["ar_SA", "en_US"]) == "ar-SA")
        #expect(VoiceAvailability.locale(for: .en, supported: ["EN_us"]) == "EN-us")
    }

    @Test func `a language the phone lacks has no locale, and a lookalike prefix is not it`() {
        #expect(VoiceAvailability.locale(for: .ar, supported: ["en-US", "fr-FR"]) == nil)
        #expect(VoiceAvailability.locale(for: .en, supported: ["ar-SA", "eng-XX"]) == nil)
        #expect(VoiceAvailability.locale(for: .ar, supported: ["arn-CL"]) == nil)
        #expect(VoiceAvailability.locale(for: .en, supported: []) == nil)
    }
}

@Suite("S05 voice gate: asks only from the tap, requests only on device")
struct VoiceGateTests {
    @Test func `unsupported on-device recognition is unavailable with no request made`() async {
        for lang in Lang.allCases {
            let platform = FakeSpeechPlatform(phone(onDevice: false))
            let requests = Requests()
            let result = await failure {
                try await VoiceAvailability.open(lang, on: platform) { requests.make($0) }
            }
            #expect(result == .unavailable)
            #expect(requests.locales.isEmpty)
            #expect(platform.asked.isEmpty, "No prompt for voice that could never work")
        }
    }

    @Test func `on device and allowed makes one request in the chosen locale`() async throws {
        let platform = FakeSpeechPlatform(phone(), locales: ["ar-SA", "ar-QA", "en-GB", "en-US"])
        let requests = Requests()
        let ar = try await VoiceAvailability.open(.ar, on: platform) { requests.make($0) }
        let en = try await VoiceAvailability.open(.en, on: platform) { requests.make($0) }
        #expect(ar == "listening in ar-QA")
        #expect(en == "listening in en-US")
        #expect(requests.locales == ["ar-QA", "en-US"])
        #expect(platform.conditionLocales == ["ar-QA", "en-US"])
        #expect(platform.asked.isEmpty)
    }

    @Test func `no locale for the language is unsupported, with nothing asked or requested`() async {
        let platform = FakeSpeechPlatform(phone(mic: .undetermined), locales: ["en-US"])
        let requests = Requests()
        let result = await failure {
            try await VoiceAvailability.open(.ar, on: platform) { requests.make($0) }
        }
        #expect(result == .unsupported)
        #expect(requests.locales.isEmpty)
        #expect(platform.asked.isEmpty)
    }

    @Test func `the first tap asks for the microphone, then speech, then listens`() async throws {
        let platform = FakeSpeechPlatform(phone(speech: .notDetermined, mic: .undetermined))
        let requests = Requests()
        _ = try await VoiceAvailability.open(.en, on: platform) { requests.make($0) }
        #expect(platform.asked == ["mic", "speech"])
        #expect(requests.locales == ["en-US"])
    }

    @Test func `a refused microphone is denied, and speech is not asked`() async {
        let platform = FakeSpeechPlatform(
            phone(speech: .notDetermined, mic: .undetermined), micAnswer: .denied)
        let requests = Requests()
        let result = await failure {
            try await VoiceAvailability.open(.ar, on: platform) { requests.make($0) }
        }
        #expect(result == .denied)
        #expect(platform.asked == ["mic"])
        #expect(requests.locales.isEmpty)
    }

    @Test func `refused speech recognition is denied`() async {
        let platform = FakeSpeechPlatform(phone(speech: .notDetermined), speechAnswer: .denied)
        let requests = Requests()
        let result = await failure {
            try await VoiceAvailability.open(.en, on: platform) { requests.make($0) }
        }
        #expect(result == .denied)
        #expect(platform.asked == ["speech"])
        #expect(requests.locales.isEmpty)
    }

    @Test func `a prompt dismissed with no answer reads as denied`() async {
        let platform = FakeSpeechPlatform(
            phone(speech: .notDetermined), speechAnswer: .notDetermined)
        let requests = Requests()
        let result = await failure {
            try await VoiceAvailability.open(.en, on: platform) { requests.make($0) }
        }
        #expect(result == .denied)
        #expect(requests.locales.isEmpty)
    }

    @Test func `already refused is denied with no prompt`() async {
        let platform = FakeSpeechPlatform(phone(mic: .denied))
        let requests = Requests()
        let result = await failure {
            try await VoiceAvailability.open(.ar, on: platform) { requests.make($0) }
        }
        #expect(result == .denied)
        #expect(platform.asked.isEmpty)
        #expect(requests.locales.isEmpty)
    }

    @Test func `a recogniser busy now is unavailable after asking`() async {
        let platform = FakeSpeechPlatform(phone(mic: .undetermined, available: false))
        let requests = Requests()
        let result = await failure {
            try await VoiceAvailability.open(.en, on: platform) { requests.make($0) }
        }
        #expect(result == .unavailable)
        #expect(platform.asked == ["mic"])
        #expect(requests.locales.isEmpty)
    }

    @Test func `an error from the request itself passes through`() async {
        let platform = FakeSpeechPlatform(phone())
        let result = await failure {
            try await VoiceAvailability.open(.en, on: platform) { _ -> String in
                throw VoiceFailure.failed
            }
        }
        #expect(result == .failed)
    }
}
