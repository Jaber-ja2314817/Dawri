import DawriCore
import SwiftUI

/// Consent, before S05. Do I agree to the chat? The port of
/// frontend/src/pages/patient/Consent.tsx. One short step before the first chat.
struct ConsentScreen: View {
    /// `POINTS` in Consent.tsx.
    private static let points = ["consent.why", "consent.limits", "consent.privacy", "consent.demo"]

    let patientId: String

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @State private var isBusy = false
    @State private var error: (any Error)?

    /// Named only when the visit is for someone else.
    private var dependent: Patient? {
        model.me?.dependents.first { $0.id == patientId }
    }

    var body: some View {
        PatientScaffold(title: lang.t("consent.title")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let dependent {
                    // A name keeps its own direction, so it is isolated as `auto`, not `ltr`.
                    Text(verbatim: lang.t("consent.forPerson", ["name": Bidi.auto(nameOf(dependent, lang: lang))]))
                        .dsText(.body)
                        .foregroundStyle(DS.Color.muted)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(Text(verbatim: lang.t("consent.forPerson", ["name": nameOf(dependent, lang: lang)])))
                        .accessibilityIdentifier("consent-for")
                }
                Card {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        ForEach(Self.points, id: \.self) { key in
                            Text(verbatim: lang.t(key))
                                .dsText(.body)
                                .foregroundStyle(DS.Color.ink)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let error {
                    ErrorBlock(message: errorText(error, strings: .bundled, lang: lang)) {
                        Task { await agree() }
                    }
                    .accessibilityIdentifier("consent-error")
                }
                Button(lang.t("consent.agree")) {
                    Task { await agree() }
                }
                .buttonStyle(PrimaryButtonStyle())
                .dsLoading(isBusy)
                .accessibilityIdentifier("consent-agree")
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-consent")
        }
        #if DEBUG
        .task {
            if DemoAccount.agrees, DemoAccount.once("agree") { await agree() }
        }
        #endif
    }

    /// `agree` in Consent.tsx. Never a new chat after an emergency today, and never a second
    /// visit: both refusals carry the visit they mean, and that is where the patient goes.
    private func agree() async {
        guard !isBusy else { return }
        isBusy = true
        error = nil
        do {
            let created = try await model.service.createVisit(patientId: patientId)
            model.enterVisit(created.visitId, screen: .chat)
        } catch {
            if model.sessionEnded(by: error) { return }
            if let refusal = error as? ClinicError, case .string(let visitId)? = refusal.extra["visit_id"] {
                switch refusal.code {
                case "emergency_today":
                    model.showEmergency(visitId: visitId, redFlag: false)
                    return
                case "active_visit":
                    model.enterVisit(visitId)
                    return
                default:
                    break
                }
            }
            self.error = error
            isBusy = false
        }
    }
}
