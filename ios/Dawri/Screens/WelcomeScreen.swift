import DawriCore
import SwiftUI

/// S01. What is this, and how do I start?
struct WelcomeScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        PatientScaffold(title: nil, showsProductTitle: false, footer: .flow, footerGap: DS.Space.l) {
            VStack(alignment: .leading, spacing: 0) {
                if typeSize.isAccessibilitySize {
                    Color.clear.frame(height: DS.Space.l)
                } else {
                    // The lockup hangs from this line, so a language switch moves nothing.
                    Color.clear.containerRelativeFrame(.vertical) { height, _ in height * 0.18 }
                }
                ProductLockup()
                Text(verbatim: lang.t("welcome.purpose"))
                    .dsText(.lead)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, DS.Space.m)
                    .accessibilityIdentifier("welcome-purpose")
                Spacer(minLength: DS.Space.xl)
                Button(lang.t("welcome.login")) {
                    model.open(.login)
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("welcome-login")
            }
            .frame(maxHeight: .infinity)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-welcome")
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    model.open(.settings)
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(DS.Color.ink)
                        .frame(width: DS.Size.minTarget, height: DS.Size.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityShowsLargeContentViewer()
                .accessibilityLabel(Text(verbatim: lang.t("settings.title")))
                .accessibilityIdentifier("settings-gear")
            }
        }
    }
}
