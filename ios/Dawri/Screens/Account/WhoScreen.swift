import DawriCore
import SwiftUI

/// S04. Who is the visit for? The port of frontend/src/pages/patient/Who.tsx. With nobody else
/// to choose, this is Consent for the patient, with no frame of this screen first, as the web's
/// `<Navigate replace>`.
struct WhoScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @State private var rowTaps = 0

    var body: some View {
        if let me = model.me, me.dependents.isEmpty {
            ConsentScreen(patientId: me.patient.id)
        } else {
            PatientScaffold(title: lang.t("who.title")) {
                content
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("screen-who")
            }
            .sensoryFeedback(DS.Haptic.select, trigger: rowTaps)
            #if DEBUG
            .task(id: model.me?.patient.id) { demoPick() }
            #endif
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.meState == .failed, model.me == nil {
            ErrorBlock(message: errorText(model.meError ?? ClinicError.network, strings: .bundled, lang: lang)) {
                Task { await model.reloadMe() }
            }
            .accessibilityIdentifier("who-error")
        } else if let me = model.me {
            Card(flush: true) {
                VStack(spacing: 0) {
                    row(me.patient, isSelf: true, showsRule: false)
                    ForEach(me.dependents, id: \.id) { dependent in
                        row(dependent, isSelf: false, showsRule: true)
                    }
                }
            }
        } else {
            SkeletonBar(height: 168)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: lang.t("common.loading")))
                .accessibilityIdentifier("who-loading")
        }
    }

    /// `Person` in Who.tsx: Me, then the name and age; a dependent, then their age.
    private func row(_ person: Patient, isSelf: Bool, showsRule: Bool) -> some View {
        let age = Bidi.fill("who.age", ["age": person.age], lang: lang)
        return Button {
            rowTaps += 1
            model.open(.consent(patientId: person.id))
        } label: {
            ListRow(
                title: isSelf ? lang.t("who.me") : nameOf(person, lang: lang),
                subtitle: isSelf ? VisitRules.detailLine([nameOf(person, lang: lang), age]) : age,
                showsRule: showsRule)
        }
        .buttonStyle(ListRowButtonStyle())
        .accessibilityIdentifier("who-\(person.id)")
    }

    #if DEBUG
    /// `-demoPick`: the row tap, once the people are known.
    private func demoPick() {
        guard let id = DemoAccount.pick, let me = model.me,
              ([me.patient] + me.dependents).contains(where: { $0.id == id }),
              DemoAccount.once("pick")
        else { return }
        model.open(.consent(patientId: id))
    }
    #endif
}
