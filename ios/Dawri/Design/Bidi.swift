import DawriCore
import SwiftUI

/// Unicode isolates for mixed text, never LRM or RLM marks. Strip them with `strip` from any
/// accessibility label and any string sent to the service.
enum Bidi {
    private static let isolates: Set<Unicode.Scalar> = ["\u{2066}", "\u{2067}", "\u{2068}", "\u{2069}"]

    /// A number, code or figure inside a sentence.
    static func ltr(_ text: String) -> String {
        "\u{2066}\(text)\u{2069}"
    }

    /// Text whose language is unknown, the web's `dir="auto"`.
    static func auto(_ text: String) -> String {
        "\u{2068}\(text)\u{2069}"
    }

    /// The port of `Filled`: a translated sentence with each value kept left to right.
    static func fill(_ key: String, _ vars: Strings.Vars, lang: Lang) -> String {
        lang.t(key, vars.mapValues { ltr($0.description) })
    }

    static func strip(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { !isolates.contains($0) }))
    }
}
