import DawriCore
import SwiftUI

/// S07. Can I get this without a visit? The port of frontend/src/pages/patient/Refill.tsx. This
/// route never shows a ticket or a number, and `refill.message` sends nothing anywhere: it only
/// says the demo is not connected to a real channel.
struct RefillScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model

    var body: some View {
        RefillContent(visit: visit, watcher: watcher, model: model)
    }
}

private struct RefillContent: View {
    let visit: Visit
    let watcher: VisitWatcher
    let model: AppModel

    @Environment(\.lang) private var lang
    @State private var refill: RefillModel

    init(visit: Visit, watcher: VisitWatcher, model: AppModel) {
        self.visit = visit
        self.watcher = watcher
        self.model = model
        _refill = State(initialValue: RefillModel(service: model.service, visitId: visit.visitId))
    }

    /// An unknown value stays as stored: it keeps its own order on the screen's own side.
    private var medicine: String {
        visit.refill.map { Strings.bundled.recordTerm($0.medicine, lang: lang) }
            ?? lang.t("refill.usualMedicine")
    }

    var body: some View {
        PatientScaffold(title: lang.t("refill.title")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                Card {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(verbatim: lang.t("refill.medicine"))
                            .dsText(.secondary)
                            .foregroundStyle(DS.Color.muted)
                        Text(verbatim: Bidi.auto(medicine))
                            .dsText(.section)
                            .foregroundStyle(DS.Color.ink)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(Text(verbatim: medicine))
                            .accessibilityIdentifier("refill-medicine")
                    }
                }
                Text(verbatim: lang.t("refill.body"))
                    .dsText(.body)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(lang.t("refill.message")) {
                    refill.message()
                }
                .buttonStyle(PrimaryButtonStyle())
                .accessibilityIdentifier("refill-message")
                if refill.noticed {
                    Notice(lang.t("refill.notice"))
                        .accessibilityIdentifier("refill-notice")
                        .onAppear {
                            AccessibilityNotification.Announcement(lang.t("refill.notice")).post()
                        }
                }
                if let error = refill.error {
                    ErrorBlock(message: errorText(error, strings: .bundled, lang: lang)) {
                        Task { await wantVisit() }
                    }
                    .accessibilityIdentifier("refill-error")
                }
                Button(lang.t("refill.visit")) {
                    Task { await wantVisit() }
                }
                .buttonStyle(SecondaryButtonStyle())
                .dsLoading(refill.isBusy)
                .accessibilityIdentifier("refill-visit")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-refill")
        }
        #if DEBUG
        .task {
            switch DemoLaunch.current?.argument("demoRefillAction") {
            case "message": refill.message()
            case "visit": await wantVisit()
            default: break
            }
        }
        #endif
    }

    /// "I still want a visit": on to S08 as a GP visit, in place of this screen.
    private func wantVisit() async {
        let id = visit.visitId
        await refill.wantVisit(
            refetch: { [watcher] in
                await watcher.refetch()
                return watcher.visit
            },
            movedOn: {
                Task {
                    await model.replace(
                        .visit(id: id, screen: .refill), with: .visit(id: id, screen: .centre))
                }
            })
        if let error = refill.error { _ = model.sessionEnded(by: error) }
    }
}
