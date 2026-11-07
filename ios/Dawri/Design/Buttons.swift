import SwiftUI

extension EnvironmentValues {
    @Entry var dsIsLoading = false
}

extension View {
    /// Keeps the label, adds a spinner before it in the button styles, and disables the button.
    func dsLoading(_ isLoading: Bool) -> some View {
        environment(\.dsIsLoading, isLoading).disabled(isLoading)
    }
}

/// What a button style chooses: three looks, and the shape they go on.
private struct ButtonLook {
    var fill: Color
    var text: Color
    var edge: Color?
}

/// The shell of every filled button. Presses at touch-down with `.press`, returns with
/// `.release`, and drops the scale under Reduce Motion while the fill change stays.
private struct ShellLabel: View {
    let configuration: ButtonStyleConfiguration
    let rest: ButtonLook
    let pressed: ButtonLook
    let disabled: ButtonLook
    let role: DS.TextRole
    let minHeight: CGFloat
    var fullWidth = true
    var sidePadding: CGFloat = DS.Space.l

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.dsIsLoading) private var isLoading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isPressed = configuration.isPressed
        let look = !isEnabled ? disabled : (isPressed ? pressed : rest)
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        HStack(spacing: DS.Space.s) {
            if isLoading {
                ProgressView().tint(look.text)
            }
            configuration.label
                .dsText(role)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(look.text)
        .padding(.horizontal, sidePadding)
        .padding(.vertical, DS.Space.s)
        .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: minHeight)
        .background(look.fill, in: shape)
        .overlay {
            if let edge = look.edge {
                shape.strokeBorder(edge, lineWidth: DS.Stroke.edge)
            }
        }
        .contentShape(shape)
        .scaleEffect(isPressed && !reduceMotion ? 0.97 : 1)
        .animation(
            DS.Motion.resolved(isPressed ? DS.Motion.press : DS.Motion.release, reduceMotion: reduceMotion),
            value: isPressed)
    }
}

private let secondaryRest = ButtonLook(fill: DS.Color.surface, text: DS.Color.ink, edge: DS.Color.control)
private let secondaryPressed = ButtonLook(fill: DS.Color.raised, text: DS.Color.ink, edge: DS.Color.control)
private let secondaryDisabled = ButtonLook(
    fill: DS.Color.surface, text: DS.Color.disabledText, edge: DS.Color.hairline)

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellLabel(
            configuration: configuration,
            rest: ButtonLook(fill: DS.Color.primaryFill, text: DS.Color.primaryText),
            pressed: ButtonLook(fill: DS.Color.primaryPressed, text: DS.Color.primaryText),
            disabled: ButtonLook(fill: DS.Color.disabledFill, text: DS.Color.disabledText),
            role: .button, minHeight: DS.Size.button)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellLabel(
            configuration: configuration, rest: secondaryRest, pressed: secondaryPressed,
            disabled: secondaryDisabled, role: .button, minHeight: DS.Size.button)
    }
}

/// Text and edge only: full red stays on S06.
struct DestructiveButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellLabel(
            configuration: configuration,
            rest: ButtonLook(fill: DS.Color.surface, text: DS.Color.negative, edge: DS.Color.negative),
            pressed: ButtonLook(
                fill: DS.Color.pillNegativeFill, text: DS.Color.negative, edge: DS.Color.negative),
            disabled: secondaryDisabled, role: .button, minHeight: DS.Size.button)
    }
}

/// Never disabled, and nothing on it waits: no haptic, no animation of ours past the press.
struct EmergencyCallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellLabel(
            configuration: configuration,
            rest: ButtonLook(fill: DS.Emergency.callFill, text: DS.Emergency.callText),
            pressed: ButtonLook(fill: DS.Emergency.callPressed, text: DS.Emergency.callText),
            disabled: ButtonLook(fill: DS.Emergency.callFill, text: DS.Emergency.callText),
            role: .callButton, minHeight: DS.Size.buttonLarge)
    }
}

/// Hugs its label, for the wrapping chip rows.
struct ChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ShellLabel(
            configuration: configuration, rest: secondaryRest, pressed: secondaryPressed,
            disabled: secondaryDisabled, role: .label, minHeight: DS.Size.minTarget,
            fullWidth: false, sidePadding: DS.Space.m)
    }
}

/// `ink` text with no fill. `underlined` is for the retry in `ErrorBlock`; otherwise only
/// Button Shapes underlines it. The tone exists for S06, where the text is `emergencyText`.
struct QuietButtonStyle: ButtonStyle {
    var underlined = false
    var tone: ScaffoldTone = .default

    func makeBody(configuration: Configuration) -> some View {
        QuietLabel(configuration: configuration, underlined: underlined, tone: tone)
    }
}

private struct QuietLabel: View {
    let configuration: ButtonStyleConfiguration
    let underlined: Bool
    let tone: ScaffoldTone

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityShowButtonShapes) private var buttonShapes
    @Environment(\.dsIsLoading) private var isLoading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let text = tone == .emergency ? DS.Emergency.text : DS.Color.ink
        HStack(spacing: DS.Space.s) {
            if isLoading {
                ProgressView().tint(text)
            }
            configuration.label
                .dsText(.label)
                .underline(underlined || buttonShapes)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(isEnabled ? text : DS.Color.muted)
        .frame(minWidth: DS.Size.minTarget, minHeight: DS.Size.minTarget)
        .contentShape(Rectangle())
        .opacity(configuration.isPressed ? 0.6 : 1)
        .animation(
            DS.Motion.resolved(
                configuration.isPressed ? DS.Motion.press : DS.Motion.release,
                reduceMotion: reduceMotion),
            value: configuration.isPressed)
    }
}
