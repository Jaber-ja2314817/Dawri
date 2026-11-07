import DawriCore
import SwiftUI
import UIKit

/// The design system's tokens. Every value here comes from iOS Design, and a screen never
/// writes a colour, a size or a spring of its own.
enum DS {
    enum Color {
        static let ground = SwiftUI.Color(dsHex: DSPalette.ground)
        static let surface = SwiftUI.Color(dsHex: DSPalette.surface)
        static let raised = SwiftUI.Color(dsHex: DSPalette.raised)
        static let skeleton = SwiftUI.Color(dsHex: DSPalette.skeleton)
        static let hairline = SwiftUI.Color(dsHex: DSPalette.hairline)
        static let rule = SwiftUI.Color(dsHex: DSPalette.rule)
        static let control = SwiftUI.Color(dsHex: DSPalette.control)
        static let ink = SwiftUI.Color(dsHex: DSPalette.ink)
        static let muted = SwiftUI.Color(dsHex: DSPalette.muted)
        static let primaryFill = SwiftUI.Color(dsHex: DSPalette.primaryFill)
        static let primaryPressed = SwiftUI.Color(dsHex: DSPalette.primaryPressed)
        static let primaryText = SwiftUI.Color(dsHex: DSPalette.primaryText)
        static let disabledFill = SwiftUI.Color(dsHex: DSPalette.disabledFill)
        static let disabledText = SwiftUI.Color(dsHex: DSPalette.disabledText)
        /// The one hue. Only the patient's own number and current stage.
        static let hue = SwiftUI.Color(dsHex: DSPalette.hue)
        static let positive = SwiftUI.Color(dsHex: DSPalette.positive)
        /// Text and thin edges only, never a fill.
        static let negative = SwiftUI.Color(dsHex: DSPalette.negative)
        static let warning = SwiftUI.Color(dsHex: DSPalette.warning)
        static let pillPositiveFill = SwiftUI.Color(dsHex: DSPalette.pillPositiveFill)
        static let pillPositiveText = SwiftUI.Color(dsHex: DSPalette.pillPositiveText)
        static let pillNegativeFill = SwiftUI.Color(dsHex: DSPalette.pillNegativeFill)
        static let pillNegativeText = SwiftUI.Color(dsHex: DSPalette.pillNegativeText)
        static let pillWarningFill = SwiftUI.Color(dsHex: DSPalette.pillWarningFill)
        static let pillWarningText = SwiftUI.Color(dsHex: DSPalette.pillWarningText)
        static let pillNeutralFill = SwiftUI.Color(dsHex: DSPalette.pillNeutralFill)
        static let pillNeutralText = SwiftUI.Color(dsHex: DSPalette.pillNeutralText)
        static let noticeFill = SwiftUI.Color(dsHex: DSPalette.noticeFill)
        static let noticeEdge = SwiftUI.Color(dsHex: DSPalette.noticeEdge)
        static let noticeText = SwiftUI.Color(dsHex: DSPalette.noticeText)
    }

    /// The S06 set. The same in both themes on purpose, and only Increase Contrast changes it.
    enum Emergency {
        static let field = SwiftUI.Color(dsHex: DSPalette.emergencyField)
        static let pressed = SwiftUI.Color(dsHex: DSPalette.emergencyPressed)
        static let text = SwiftUI.Color(dsHex: DSPalette.emergencyText)
        static let callFill = SwiftUI.Color(dsHex: DSPalette.emergencyCallFill)
        static let callText = SwiftUI.Color(dsHex: DSPalette.emergencyCallText)
        static let callPressed = SwiftUI.Color(dsHex: DSPalette.emergencyCallPressed)
        static let card = SwiftUI.Color(dsHex: DSPalette.emergencyCard)
        static let cardText = SwiftUI.Color(dsHex: DSPalette.emergencyCardText)
        static let cardMuted = SwiftUI.Color(dsHex: DSPalette.emergencyCardMuted)
        static let link = SwiftUI.Color(dsHex: DSPalette.emergencyLink)
    }

    enum Space {
        static let xxs: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let card: CGFloat = 8
        static let control: CGFloat = 6
    }

    enum Stroke {
        static let edge: CGFloat = 1
        static let focus: CGFloat = 2
    }

    enum Size {
        static let minTarget: CGFloat = 44
        static let button: CGFloat = 50
        static let buttonLarge: CGFloat = 56
        static let field: CGFloat = 48
        static let row: CGFloat = 44
        static let rowTwoLine: CGFloat = 56
        static let markWidth: CGFloat = 132
        static let markHeight: CGFloat = 66
        static let stageDot: CGFloat = 12
        static let stageDotCompact: CGFloat = 8
    }

    /// Named springs only, all critically damped. Reduce Motion goes through `resolved`.
    enum Motion {
        static let push = Animation.spring(response: 0.40, dampingFraction: 1.0)
        static let sheet = Animation.spring(response: 0.35, dampingFraction: 1.0)
        static let press = Animation.spring(response: 0.12, dampingFraction: 1.0)
        static let release = Animation.spring(response: 0.28, dampingFraction: 1.0)
        static let stage = Animation.spring(response: 0.40, dampingFraction: 1.0)
        static let number = Animation.spring(response: 0.30, dampingFraction: 1.0)
        static let crossfade = Animation.easeInOut(duration: 0.18)
        /// The seconds of `crossfade`, for the one place UIKit runs it.
        static let crossfadeSeconds: TimeInterval = 0.18

        static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
            reduceMotion ? crossfade : animation
        }
    }

    /// Few on purpose, each on the same state change that drives the visual.
    enum Haptic {
        static let stageChange = SensoryFeedback.success
        static let called = SensoryFeedback.warning
        static let visitComplete = SensoryFeedback.success
        static let activated = SensoryFeedback.success
        static let failed = SensoryFeedback.error
        static let sent = SensoryFeedback.impact(weight: .light)
        static let micStart = SensoryFeedback.impact(weight: .medium)
        static let micStop = SensoryFeedback.impact(weight: .light)
        static let select = SensoryFeedback.selection
        static let scanned = SensoryFeedback.success

        /// S06 appearing. Fire and forget, once, with nothing awaiting it. Call 999 has no
        /// haptic at all, so nothing sits on the path to the call.
        @MainActor
        static func emergency() {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
    }
}

extension SwiftUI.Color {
    /// A dynamic colour that reads the theme and Increase Contrast from the trait collection.
    init(dsHex hex: DSHex) {
        self.init(uiColor: UIColor(dsHex: hex))
    }
}

extension UIColor {
    convenience init(dsHex hex: DSHex) {
        self.init { traits in
            let high = traits.accessibilityContrast == .high
            let value = traits.userInterfaceStyle == .dark
                ? (high ? hex.darkHigh : hex.dark)
                : (high ? hex.lightHigh : hex.light)
            return UIColor(
                red: CGFloat((value >> 16) & 0xff) / 255,
                green: CGFloat((value >> 8) & 0xff) / 255,
                blue: CGFloat(value & 0xff) / 255,
                alpha: 1)
        }
    }
}
