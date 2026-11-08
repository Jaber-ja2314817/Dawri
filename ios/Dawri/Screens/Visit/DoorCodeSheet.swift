import DawriCore
import SwiftUI

/// S09's door code, in a sheet at `.large`. When the camera may be used, its preview sits above
/// the typed field and reads the QR code on the door. Opening the sheet is the patient's tap, so
/// a camera not yet asked for is asked for then. Otherwise, as on the simulator or with the camera
/// refused, the sheet shows the typed field only, with `reserved.cameraUnavailable`.
///
/// A read is checked with `DoorScan.code(fromPayload:)`. A door code plays `scanned` and goes
/// through the same submit as a typed one. Anything else, a link included, is ignored and the
/// camera keeps looking: nothing read is ever opened. The code is read left to right, with Latin
/// digits, and `error.wrong_door` sits under the field.
///
/// The sheet sets no background of its own, so the system's sheet shows through.
struct DoorCodeSheet: View {
    @Binding var code: String
    let isBusy: Bool
    let wrongDoor: Bool
    let scanner: any DoorScanner
    let onEdit: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var camera: CameraAccess?
    @State private var scans = 0

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
                cameraBlock
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
        .sensoryFeedback(DS.Haptic.scanned, trigger: scans)
        .task {
            // The sheet opened from the patient's tap, so asking here is asking on that tap.
            let now = await scanner.access()
            camera = now
            if now == .needsPermission {
                camera = await scanner.requestAccess()
            }
        }
    }

    // The camera

    @ViewBuilder
    private var cameraBlock: some View {
        switch camera {
        case .available:
            VStack(alignment: .leading, spacing: DS.Space.s) {
                scanner.preview(onRead: read)
                    .frame(maxWidth: .infinity)
                    .frame(height: typeSize.isAccessibilitySize ? 220 : 280)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                    .environment(\.layoutDirection, .leftToRight)
                    .accessibilityElement()
                    .accessibilityAddTraits(.isImage)
                    .accessibilityLabel(Text(verbatim: lang.t("reserved.cameraLabel")))
                    .accessibilityHint(Text(verbatim: lang.t("reserved.scanHint")))
                    .accessibilityIdentifier("door-camera")
                Text(verbatim: lang.t("reserved.scanHint"))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.muted)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // The preview's hint says this already.
                    .accessibilityHidden(true)
            }
        case .denied, .unavailable:
            Text(verbatim: lang.t("reserved.cameraUnavailable"))
                .dsText(.secondary)
                .foregroundStyle(DS.Color.muted)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("door-camera-unavailable")
        case .needsPermission, nil:
            // Waiting on the answer. The typed field is already there.
            EmptyView()
        }
    }

    /// A read from the camera. A door code goes the way a typed one does. Anything else is
    /// ignored, with nothing new on screen, and the camera keeps looking.
    private func read(_ payload: String) -> Bool {
        guard let door = DoorScan.code(fromPayload: payload), !isBusy else { return false }
        code = door
        scans += 1
        onSubmit()
        return true
    }

    private func submit() {
        guard !trimmed.isEmpty, !isBusy else { return }
        onSubmit()
    }
}
