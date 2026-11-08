import Foundation

/// The port of frontend/src/features/chat/send.ts, plus `clock` from voiceText.ts and the unsent
/// rule from ChatScreen.tsx. Nothing here reads a rule of the engine: these only decide how a
/// turn is sent and shown.
public enum ChatRules {
    /// `TURN_TIMEOUT_MS`: the most one request may take before the patient is told.
    public static let turnTimeout = Duration.seconds(45)

    /// `MAX_TEXT`: the box and the transcript field, counted as the web counts, in UTF-16 units.
    public static let maxText = 2000

    /// Mirrors the backend's NOT_A_QUESTION: the stored slot of a turn that asked nothing.
    public static let summarySlot = "summary"

    /// What the 45 s limit throws, as the web's `AbortError`.
    public static func isAbort(_ error: any Error) -> Bool {
        error is CancellationError
    }

    /// The request may have reached the server, so only the visit can say what happened to it.
    public static func isUnknownOutcome(_ error: any Error) -> Bool {
        if isAbort(error) { return true }
        guard let clinic = error as? ClinicError else { return false }
        return clinic.status == 0 || clinic.status >= 500
    }

    /// Only messages past the count from before the send: a patient can say "no" twice.
    public static func isStored(_ messages: [ChatMessage], baseline: Int, text: String) -> Bool {
        messages.dropFirst(baseline).contains { $0.role == .user && $0.content == text }
    }

    /// The server's read-back ends by asking; the card asks that itself, in the screen's language.
    /// Exactly the web's two endings, with the white space around them.
    public static func withoutClosingQuestion(_ summary: String) -> String {
        // `\s*(...)\s*$`: white space may follow the question, and goes with it.
        let end = summary.trimmingTrailingWhitespace()
        for ending in ["Is this right?", "هل هذا صحيح؟"] where end.hasSuffix(ending) {
            return String(end.dropLast(ending.count)).trimmingTrailingWhitespace()
        }
        return summary
    }

    /// What is sent: the words with any Unicode isolate the screen added taken out, then trimmed
    /// as JavaScript's `trim` does. Nothing else is changed, so the rules read what was typed.
    public static func outgoing(_ raw: String) -> String {
        stripIsolates(raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// U+2066 to U+2069, the isolates `Bidi` wraps text in.
    public static func stripIsolates(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !(0x2066...0x2069).contains($0.value) }))
    }

    /// The input's `maxLength`, which counts UTF-16 units. A character that would cross the limit
    /// is left out whole, so a surrogate pair is never split.
    public static func limited(_ text: String) -> String {
        guard text.utf16.count > maxText else { return text }
        var units = 0
        var kept = ""
        for character in text {
            units += character.utf16.count
            if units > maxText { break }
            kept.append(character)
        }
        return kept
    }

    /// Whether the words are empty to the chat, as `draft.trim() === ''`.
    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// `voiceHolds` and `unsent` in ChatScreen.tsx. Rules read only what is sent, so words still
    /// on their way hold back the Yes on the summary: text in the box, a transcript waiting to be
    /// sent, or a recording about to bring one.
    public static func hasUnsentWords(draft: String, voiceStep: VoiceStep, transcript: String) -> Bool {
        let voiceHolds = voiceStep == .confirm ? !isBlank(transcript) : voiceStep != .idle
        return !isBlank(draft) || voiceHolds
    }

    /// `clock` in voiceText.ts: M:SS, always Latin digits.
    public static func clock(_ seconds: Int) -> String {
        let whole = max(0, seconds)
        let rest = whole % 60
        return "\(whole / 60):\(rest < 10 ? "0" : "")\(rest)"
    }
}

extension String {
    fileprivate func trimmingTrailingWhitespace() -> String {
        var end = endIndex
        while end > startIndex {
            let before = index(before: end)
            guard self[before].isWhitespace else { break }
            end = before
        }
        return String(self[..<end])
    }
}
