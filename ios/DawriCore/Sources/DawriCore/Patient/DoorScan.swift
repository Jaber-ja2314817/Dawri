import Foundation

/// What a QR code on S09's door scanner may be: a `DOOR-<centre id>` code and nothing else
/// (Build Decisions F19, `DOOR-<centre id>` in backend/routers/visits.py). A payload is only
/// ever read as text. It is never opened, followed or shown as a link.
public enum DoorScan {
    /// The longest payload looked at. A door code is about a dozen characters.
    public static let maxLength = 64

    /// The door code in a payload, as the clinic reads it through `TicketRules.doorCode`
    /// (trimmed, upper case, Latin digits), or nil when the payload is anything else, such as
    /// a link, a centre id alone, or text with spaces in it. Whether it is this visit's door is
    /// the clinic's to say, exactly as for a typed code.
    public static func code(fromPayload payload: String) -> String? {
        guard payload.count <= maxLength,
              payload.unicodeScalars.allSatisfy({ $0.isASCII || isArabicDigit($0) })
        else { return nil }
        let code = TicketRules.doorCode(payload)
        guard code.hasPrefix("DOOR-") else { return nil }
        let id = code.dropFirst("DOOR-".count)
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ part in
                  !part.isEmpty && part.unicodeScalars.allSatisfy(isCodeScalar)
              })
        else { return nil }
        return code
    }

    /// Eastern Arabic and Persian digits, which `TicketRules.latinDigits` turns Latin. Any other
    /// letter outside ASCII is refused before upper-casing, so `ſ` cannot become `S`.
    private static func isArabicDigit(_ scalar: Unicode.Scalar) -> Bool {
        (0x0660...0x0669).contains(scalar.value) || (0x06F0...0x06F9).contains(scalar.value)
    }

    /// `A` to `Z` and `0` to `9`, in ASCII only.
    private static func isCodeScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}
