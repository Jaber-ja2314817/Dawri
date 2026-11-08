import DawriCore
import SwiftUI

/// S09's door code, in a sheet at `.large`. The camera is a later phase, so this is the sheet as
/// Design gives it when the camera is denied: the typed field and `reserved.codeSubmit`. The code
/// is read left to right, with Latin digits, and `error.wrong_door` sits under the field.
///
/// The sheet sets no background of its own, so the system's sheet shows through.
struct DoorCodeSheet: View {
    @Binding var code: String
    let isBusy: Bool
    let wrongDoor: Bool
    let onEdit: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.lang) private var lang

    private var trimmed: String {
        code.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.m) {
                    ScreenTitle(lang.t("reserved.scan"))
                    Button(lang.t("common.cancel"), action: onCancel)
                        .buttonStyle(QuietButtonStyle())
                        .accessibilityIdentifier("door-cancel")
                }
                DSTextField(
                    label: lang.t("reserved.codeLabel"), text: $code,
                    error: wrongDoor ? lang.t("error.wrong_door") : nil, kind: .qid,
                    identifier: "door-code")
                    .submitLabel(.go)
                    .onSubmit(submit)
                    .onChange(of: code) { onEdit() }
                Button(lang.t("reserved.codeSubmit"), action: submit)
                    .buttonStyle(PrimaryButtonStyle())
                    .dsLoading(isBusy)
                    .disabled(trimmed.isEmpty)
                    .accessibilityIdentifier("door-submit")
                PatientFooter()
                    .padding(.top, DS.Space.xl)
            }
            .padding(DS.Space.l)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .presentationDetents([.large])
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("door-sheet")
        .sensoryFeedback(DS.Haptic.failed, trigger: wrongDoor) { _, now in now }
    }

    private func submit() {
        guard !trimmed.isEmpty, !isBusy else { return }
        onSubmit()
    }
}
