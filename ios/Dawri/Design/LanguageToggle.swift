import DawriCore
import SwiftUI

/// Shows the other language in its own script. Top trailing on every screen, so in Arabic it
/// is on the left. The switch itself keeps the screen, see `LanguageSwitcher`.
struct LanguageToggle: View {
    var tone: ScaffoldTone = .default

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang

    var body: some View {
        let other: Lang = lang == .ar ? .en : .ar
        let name = other == .ar ? "العربية" : "English"
        Button {
            model.switchLanguage(to: other)
        } label: {
            Text(verbatim: name)
                .environment(\.lang, other)
        }
        .buttonStyle(ToggleStyle(tone: tone))
        .environment(\.layoutDirection, lang.layoutDirection)
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityShowsLargeContentViewer()
        .accessibilityLabel(Text(spokenName(name, in: other)))
        .accessibilityIdentifier("language-toggle")
    }
}

/// The label in the target language. SwiftUI has no `accessibilityLanguage` modifier, so the
/// language travels on the string.
private func spokenName(_ name: String, in lang: Lang) -> AttributedString {
    var spoken = AttributedString(name)
    spoken.languageIdentifier = lang.rawValue
    return spoken
}

private struct ToggleStyle: ButtonStyle {
    let tone: ScaffoldTone

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
        let label = configuration.label
            .dsText(.label)
            .lineLimit(1)
            .frame(minWidth: DS.Size.minTarget, minHeight: DS.Size.minTarget)
        if tone == .emergency {
            label
                .foregroundStyle(DS.Emergency.text)
                .padding(.horizontal, DS.Space.m)
                .background(configuration.isPressed ? DS.Emergency.pressed : .clear, in: shape)
                .overlay(shape.strokeBorder(DS.Emergency.text, lineWidth: DS.Stroke.edge))
                .contentShape(shape)
        } else if #available(iOS 26, *) {
            // The system's toolbar capsule is the edge here, so a border never sits inside it.
            label
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.s)
                .contentShape(Rectangle())
                .opacity(configuration.isPressed ? 0.6 : 1)
        } else {
            label
                .foregroundStyle(DS.Color.ink)
                .padding(.horizontal, DS.Space.m)
                .background(configuration.isPressed ? DS.Color.raised : DS.Color.surface, in: shape)
                .overlay(shape.strokeBorder(DS.Color.control, lineWidth: DS.Stroke.edge))
                .contentShape(shape)
        }
    }
}
