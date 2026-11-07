import DawriCore
import SwiftUI

/// One themed stand-in for every screen a later phase builds. It says so, and fakes nothing.
struct PlaceholderScreen: View {
    let id: String
    let titleKey: String
    var tone: ScaffoldTone = .default

    @Environment(\.lang) private var lang
    @Environment(AppModel.self) private var model

    var body: some View {
        PatientScaffold(title: lang.t(titleKey), tone: tone) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if id == "home", model.showsDemoReset {
                    Notice(lang.t("home.demoReset"))
                }
                Text(verbatim: lang.t("placeholder.title"))
                    .dsText(.body)
                    .foregroundStyle(tone == .emergency ? DS.Emergency.text : DS.Color.muted)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("placeholder-note")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-\(id)")
        }
    }
}
