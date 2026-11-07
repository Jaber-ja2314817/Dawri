import DawriCore
import SwiftUI

extension EnvironmentValues {
    /// The app's language, set at the root from `LanguageState`.
    @Entry var lang: Lang = .ar
}

extension DS {
    /// `DS.Type` cannot exist in Swift, so the roles of section 2 live here.
    enum TextRole: CaseIterable {
        case barTitle, screenTitle, emergencyTitle, lead, urgent, section, body, bodyStrong
        case secondary, secondaryStrong, label, caption, pill, button, callButton, statValue
        case countdown, badge, ticketNumber

        /// The role's font for a language. Arabic caption and pill step up to `.footnote`,
        /// because dots and marks collapse at 12 pt.
        func font(for lang: Lang) -> Font {
            switch self {
            case .barTitle, .section: .headline.weight(.semibold)
            case .screenTitle: .title2.weight(.semibold)
            case .emergencyTitle: .title.weight(.semibold)
            case .lead: .title3
            case .urgent: .title3.weight(.medium)
            case .body: .body
            case .bodyStrong: .body.weight(.medium)
            case .secondary: .subheadline
            case .secondaryStrong: .subheadline.weight(.semibold)
            case .label: .subheadline.weight(.medium)
            case .caption: lang == .ar ? .footnote : .caption
            case .pill:
                (lang == .ar ? Font.footnote : Font.caption).weight(.medium).monospacedDigit()
            case .button: .body.weight(.semibold).monospacedDigit()
            case .callButton, .statValue: .title3.weight(.semibold).monospacedDigit()
            case .countdown: .largeTitle.weight(.semibold).monospacedDigit()
            case .badge: .subheadline.weight(.semibold).monospacedDigit()
            case .ticketNumber: .system(size: 112, weight: .semibold).monospacedDigit()
            }
        }

        /// Arabic needs a little more room between lines. English keeps the style's own leading.
        func lineSpacing(for lang: Lang) -> CGFloat {
            guard lang == .ar else { return 0 }
            switch self {
            case .body, .bodyStrong, .secondary, .caption, .lead, .urgent: return 2
            case .screenTitle, .emergencyTitle: return 3
            default: return 0
            }
        }
    }
}

private struct DSTextModifier: ViewModifier {
    let role: DS.TextRole
    let digits: Bool
    @Environment(\.lang) private var lang

    func body(content: Content) -> some View {
        let font = role.font(for: lang)
        content
            .font(digits ? font.monospacedDigit() : font)
            .lineSpacing(role.lineSpacing(for: lang))
    }
}

extension View {
    /// The only way to set type: font, Arabic line spacing and digits. `monoDigits` is for a
    /// caption that is a clock or a date in a column.
    func dsText(_ role: DS.TextRole, monoDigits: Bool = false) -> some View {
        modifier(DSTextModifier(role: role, digits: monoDigits))
    }
}

extension Lang {
    /// The bundled string for this language. A missing key comes back as the key.
    func t(_ key: String, _ vars: Strings.Vars? = nil) -> String {
        Strings.bundled.translate(self, key, vars)
    }

    /// The root locale: Latin digits and the Gregorian calendar in both languages.
    var locale: Locale {
        Locale(identifier: self == .ar ? "ar_QA@numbers=latn;calendar=gregorian" : "en_GB")
    }

    var layoutDirection: LayoutDirection {
        dir == .rtl ? .rightToLeft : .leftToRight
    }
}
