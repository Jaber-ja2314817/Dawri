import Foundation
import Testing
@testable import DawriCore

/// The contrast table of iOS Design, section 1.2. Every published ratio is recomputed from the
/// hex table, so an edit to a colour cannot pass below its floor unnoticed.
private func luminance(_ hex: UInt32) -> Double {
    func channel(_ shift: UInt32) -> Double {
        let value = Double((hex >> shift) & 0xff) / 255
        return value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return 0.2126 * channel(16) + 0.7152 * channel(8) + 0.0722 * channel(0)
}

private func ratio(_ first: UInt32, _ second: UInt32) -> Double {
    let (a, b) = (luminance(first) + 0.05, luminance(second) + 0.05)
    return max(a, b) / min(a, b)
}

private struct Pair: Sendable, CustomTestStringConvertible {
    let foreground: DSHex
    let background: DSHex
    let floor: Double
    let published: (light: Double, dark: Double, lightHigh: Double, darkHigh: Double)
    let testDescription: String

    init(
        _ foreground: DSHex, on background: DSHex, floor: Double,
        published: (Double, Double, Double, Double),
        sourceLine: Int = #line
    ) {
        self.foreground = foreground
        self.background = background
        self.floor = floor
        self.published = published
        self.testDescription = "section 1.2 row at DesignContrastTests line \(sourceLine)"
    }
}

private let pairs: [Pair] = [
    Pair(DSPalette.ink, on: DSPalette.ground, floor: 4.5, published: (17.97, 17.19, 19.06, 18.89)),
    Pair(DSPalette.ink, on: DSPalette.surface, floor: 4.5, published: (19.80, 15.67, 21.00, 17.22)),
    Pair(DSPalette.ink, on: DSPalette.raised, floor: 4.5, published: (17.06, 13.57, 16.83, 13.75)),
    Pair(DSPalette.muted, on: DSPalette.ground, floor: 4.5, published: (4.84, 7.87, 8.04, 11.42)),
    Pair(DSPalette.muted, on: DSPalette.surface, floor: 4.5, published: (5.33, 7.17, 8.86, 10.41)),
    Pair(DSPalette.muted, on: DSPalette.raised, floor: 4.5, published: (4.59, 6.21, 7.10, 8.31)),
    Pair(DSPalette.primaryText, on: DSPalette.primaryFill, floor: 4.5, published: (19.80, 18.01, 21.00, 21.00)),
    Pair(DSPalette.primaryText, on: DSPalette.primaryPressed, floor: 4.5, published: (14.35, 13.40, 14.35, 14.21)),
    Pair(DSPalette.disabledText, on: DSPalette.disabledFill, floor: 4.5, published: (4.73, 5.73, 6.49, 7.32)),
    Pair(DSPalette.disabledText, on: DSPalette.surface, floor: 4.5, published: (7.00, 7.17, 10.86, 11.29)),
    Pair(DSPalette.disabledText, on: DSPalette.raised, floor: 4.5, published: (6.04, 6.21, 8.70, 9.01)),
    Pair(DSPalette.hue, on: DSPalette.surface, floor: 4.5, published: (6.10, 6.16, 8.56, 8.56)),
    Pair(DSPalette.hue, on: DSPalette.ground, floor: 4.5, published: (5.54, 6.76, 7.77, 9.39)),
    Pair(DSPalette.positive, on: DSPalette.surface, floor: 4.5, published: (5.13, 8.40, 8.04, 10.94)),
    Pair(DSPalette.positive, on: DSPalette.ground, floor: 3.0, published: (4.65, 9.21, 7.29, 12.01)),
    Pair(DSPalette.negative, on: DSPalette.surface, floor: 4.5, published: (5.78, 7.82, 7.86, 10.16)),
    Pair(DSPalette.negative, on: DSPalette.ground, floor: 4.5, published: (5.25, 8.57, 7.13, 11.14)),
    Pair(DSPalette.negative, on: DSPalette.pillNegativeFill, floor: 4.5, published: (5.11, 7.25, 6.94, 9.42)),
    Pair(DSPalette.warning, on: DSPalette.surface, floor: 4.5, published: (7.09, 8.90, 8.97, 10.32)),
    Pair(DSPalette.warning, on: DSPalette.ground, floor: 4.5, published: (6.43, 9.76, 8.14, 11.32)),
    Pair(DSPalette.pillPositiveText, on: DSPalette.pillPositiveFill, floor: 4.5, published: (14.77, 10.06, 14.77, 11.88)),
    Pair(DSPalette.pillNegativeText, on: DSPalette.pillNegativeFill, floor: 4.5, published: (8.63, 9.42, 10.45, 11.52)),
    Pair(DSPalette.pillWarningText, on: DSPalette.pillWarningFill, floor: 4.5, published: (6.84, 9.17, 8.65, 11.00)),
    Pair(DSPalette.pillNeutralText, on: DSPalette.pillNeutralFill, floor: 4.5, published: (9.36, 9.76, 11.50, 11.17)),
    Pair(DSPalette.noticeText, on: DSPalette.noticeFill, floor: 4.5, published: (6.84, 9.58, 8.65, 11.50)),
    Pair(DSPalette.primaryFill, on: DSPalette.ground, floor: 3.0, published: (17.97, 17.19, 19.06, 18.89)),
    Pair(DSPalette.primaryFill, on: DSPalette.surface, floor: 3.0, published: (19.80, 15.67, 21.00, 17.22)),
    Pair(DSPalette.control, on: DSPalette.surface, floor: 3.0, published: (3.69, 3.85, 5.74, 6.21)),
    Pair(DSPalette.control, on: DSPalette.ground, floor: 3.0, published: (3.35, 4.23, 5.21, 6.81)),
    Pair(DSPalette.control, on: DSPalette.raised, floor: 3.0, published: (3.18, 3.34, 4.60, 4.96)),
    Pair(DSPalette.hue, on: DSPalette.surface, floor: 3.0, published: (6.10, 6.16, 8.56, 8.56)),
    Pair(DSPalette.negative, on: DSPalette.surface, floor: 3.0, published: (5.78, 7.82, 7.86, 10.16)),
    Pair(DSPalette.emergencyText, on: DSPalette.emergencyField, floor: 4.5, published: (5.78, 5.78, 7.33, 7.33)),
    Pair(DSPalette.emergencyText, on: DSPalette.emergencyPressed, floor: 4.5, published: (7.33, 7.33, 9.10, 9.10)),
    Pair(DSPalette.emergencyCallText, on: DSPalette.emergencyCallFill, floor: 4.5, published: (19.80, 19.80, 21.00, 21.00)),
    Pair(DSPalette.emergencyCallText, on: DSPalette.emergencyCallPressed, floor: 4.5, published: (17.06, 17.06, 16.83, 16.83)),
    Pair(DSPalette.emergencyCallFill, on: DSPalette.emergencyField, floor: 3.0, published: (5.78, 5.78, 7.33, 7.33)),
    Pair(DSPalette.emergencyCardText, on: DSPalette.emergencyCard, floor: 4.5, published: (19.80, 19.80, 21.00, 21.00)),
    Pair(DSPalette.emergencyCardMuted, on: DSPalette.emergencyCard, floor: 4.5, published: (5.33, 5.33, 8.86, 8.86)),
]

@Suite("Design contrast, the hex table against section 1.2")
struct DesignContrastTests {
    @Test(arguments: pairs)
    fileprivate func `every theme clears its floor and matches the published ratio`(pair: Pair) {
        let measured = [
            ratio(pair.foreground.light, pair.background.light),
            ratio(pair.foreground.dark, pair.background.dark),
            ratio(pair.foreground.lightHigh, pair.background.lightHigh),
            ratio(pair.foreground.darkHigh, pair.background.darkHigh),
        ]
        let published = [
            pair.published.light, pair.published.dark, pair.published.lightHigh,
            pair.published.darkHigh,
        ]
        for (value, expected) in zip(measured, published) {
            #expect(value >= pair.floor)
            #expect(abs(value - expected) < 0.006)
        }
    }

    @Test func `the emergency set does not depend on the colour scheme`() {
        let set = [
            DSPalette.emergencyField, DSPalette.emergencyText, DSPalette.emergencyPressed,
            DSPalette.emergencyCallFill, DSPalette.emergencyCallText,
            DSPalette.emergencyCallPressed, DSPalette.emergencyCard, DSPalette.emergencyCardText,
            DSPalette.emergencyCardMuted, DSPalette.emergencyLink,
        ]
        for token in set {
            #expect(token.light == token.dark)
            #expect(token.lightHigh == token.darkHigh)
        }
    }

    @Test func `ink is the tint, in the asset catalog's values`() {
        #expect(DSPalette.ink.light == 0x0a0a0a)
        #expect(DSPalette.ink.dark == 0xf4f4f5)
    }
}
