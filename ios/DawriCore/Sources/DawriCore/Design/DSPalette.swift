/// One colour token: its light and dark values, and the two Increase Contrast values, as
/// sRGB hex. A token with no entry in section 1.3 of iOS Design keeps the same value there.
public struct DSHex: Sendable, Hashable {
    public let light: UInt32
    public let dark: UInt32
    public let lightHigh: UInt32
    public let darkHigh: UInt32

    public init(light: UInt32, dark: UInt32, lightHigh: UInt32? = nil, darkHigh: UInt32? = nil) {
        self.light = light
        self.dark = dark
        self.lightHigh = lightHigh ?? light
        self.darkHigh = darkHigh ?? dark
    }
}

/// The colour table of iOS Design, sections 1.1 and 1.3. It lives here so the app, the Live
/// Activity and `DesignContrastTests` all read the same values.
public enum DSPalette {
    public static let ground = DSHex(light: 0xf2f4f7, dark: 0x101113)
    public static let surface = DSHex(light: 0xffffff, dark: 0x1a1b1e)
    public static let raised = DSHex(
        light: 0xeeeeee, dark: 0x26272b,
        lightHigh: 0xe6e6e6, darkHigh: 0x2c2d31)
    public static let skeleton = DSHex(
        light: 0xe3e5e9, dark: 0x2c2d31,
        lightHigh: 0xd4d6da, darkHigh: 0x3a3b40)
    public static let hairline = DSHex(
        light: 0xe6e6e6, dark: 0x2c2d31,
        lightHigh: 0xa3a3a3, darkHigh: 0x56575c)
    public static let rule = DSHex(
        light: 0xefefef, dark: 0x232428,
        lightHigh: 0xc4c4c4, darkHigh: 0x3f4045)
    public static let control = DSHex(
        light: 0x858585, dark: 0x76777c,
        lightHigh: 0x666666, darkHigh: 0x9a9ba0)
    public static let ink = DSHex(
        light: 0x0a0a0a, dark: 0xf4f4f5,
        lightHigh: 0x000000, darkHigh: 0xffffff)
    public static let muted = DSHex(
        light: 0x6b6b6b, dark: 0xa6a7ac,
        lightHigh: 0x4a4a4a, darkHigh: 0xc8c9cd)
    public static let primaryFill = DSHex(
        light: 0x0a0a0a, dark: 0xf4f4f5,
        lightHigh: 0x000000, darkHigh: 0xffffff)
    public static let primaryPressed = DSHex(light: 0x2a2a2a, dark: 0xd4d4d8)
    public static let primaryText = DSHex(
        light: 0xffffff, dark: 0x0a0a0a,
        lightHigh: 0xffffff, darkHigh: 0x000000)
    public static let disabledFill = DSHex(
        light: 0xd4d4d4, dark: 0x2c2d31,
        lightHigh: 0xc8c8c8, darkHigh: 0x3a3b40)
    public static let disabledText = DSHex(
        light: 0x595959, dark: 0xa6a7ac,
        lightHigh: 0x3d3d3d, darkHigh: 0xd0d1d5)
    public static let hue = DSHex(
        light: 0x1d5fbf, dark: 0x689ce8,
        lightHigh: 0x164a96, darkHigh: 0x91b9f3)
    public static let positive = DSHex(
        light: 0x2e7d32, dark: 0x62c98a,
        lightHigh: 0x1f5c23, darkHigh: 0x8ae0ad)
    public static let negative = DSHex(
        light: 0xc4242a, dark: 0xff8f87,
        lightHigh: 0xa01b20, darkHigh: 0xffb4ad)
    public static let warning = DSHex(
        light: 0x92400e, dark: 0xe8b06a,
        lightHigh: 0x7a350b, darkHigh: 0xf2c078)
    public static let pillPositiveFill = DSHex(light: 0xdcfae5, dark: 0x16291d)
    public static let pillPositiveText = DSHex(
        light: 0x04250e, dark: 0x8fe3ae,
        lightHigh: 0x04250e, darkHigh: 0xb4f0ca)
    public static let pillNegativeFill = DSHex(light: 0xffedea, dark: 0x331b1c)
    public static let pillNegativeText = DSHex(
        light: 0x831c1e, dark: 0xffb4ad,
        lightHigh: 0x6e1416, darkHigh: 0xffd0cb)
    public static let pillWarningFill = DSHex(light: 0xfffbeb, dark: 0x30230f)
    public static let pillWarningText = DSHex(
        light: 0x92400e, dark: 0xf2c078,
        lightHigh: 0x7a350b, darkHigh: 0xf7d6a3)
    public static let pillNeutralFill = DSHex(
        light: 0xeeeeee, dark: 0x2c2d31,
        lightHigh: 0xe6e6e6, darkHigh: 0x3a3b40)
    public static let pillNeutralText = DSHex(
        light: 0x3d3d3d, dark: 0xd9d9dc,
        lightHigh: 0x2a2a2a, darkHigh: 0xffffff)
    public static let noticeFill = DSHex(light: 0xfffbeb, dark: 0x2a2012)
    public static let noticeEdge = DSHex(
        light: 0xfde68a, dark: 0x5c4520,
        lightHigh: 0xb98a1e, darkHigh: 0x8a6a30)
    public static let noticeText = DSHex(
        light: 0x92400e, dark: 0xf2c078,
        lightHigh: 0x7a350b, darkHigh: 0xf7d6a3)
    public static let emergencyField = DSHex(
        light: 0xc4242a, dark: 0xc4242a,
        lightHigh: 0xa81d23, darkHigh: 0xa81d23)
    public static let emergencyText = DSHex(light: 0xffffff, dark: 0xffffff)
    public static let emergencyPressed = DSHex(
        light: 0xa81d23, dark: 0xa81d23,
        lightHigh: 0x8f171c, darkHigh: 0x8f171c)
    public static let emergencyCallFill = DSHex(light: 0xffffff, dark: 0xffffff)
    public static let emergencyCallText = DSHex(
        light: 0x0a0a0a, dark: 0x0a0a0a,
        lightHigh: 0x000000, darkHigh: 0x000000)
    public static let emergencyCallPressed = DSHex(
        light: 0xeeeeee, dark: 0xeeeeee,
        lightHigh: 0xe6e6e6, darkHigh: 0xe6e6e6)
    public static let emergencyCard = DSHex(light: 0xffffff, dark: 0xffffff)
    public static let emergencyCardText = DSHex(
        light: 0x0a0a0a, dark: 0x0a0a0a,
        lightHigh: 0x000000, darkHigh: 0x000000)
    public static let emergencyCardMuted = DSHex(
        light: 0x6b6b6b, dark: 0x6b6b6b,
        lightHigh: 0x4a4a4a, darkHigh: 0x4a4a4a)
    /// In section 1.3 only. At rest it is the card text, which is also the map link.
    public static let emergencyLink = DSHex(
        light: 0x0a0a0a, dark: 0x0a0a0a, lightHigh: 0x000000, darkHigh: 0x000000)
}
