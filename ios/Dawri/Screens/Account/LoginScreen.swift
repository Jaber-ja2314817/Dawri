import DawriCore
import SwiftUI

/// S02. Who are you? The port of frontend/src/pages/patient/Login.tsx. The chips come first,
/// because they are the three-tap demo path, then the form.
///
/// Typed text lives in `@State`. That is enough here: the stack is never rebuilt, so a language
/// switch re-renders this screen in place and keeps what was typed.
struct LoginScreen: View {
    /// `DEMO_OTP` in Login.tsx.
    private static let demoOtp = "0000"

    /// `DEMO_CHIPS` in Login.tsx: the three vault demo patients. Anyone else in the seed logs in
    /// by typing their QID. Constants, so the chips need no read.
    private static let chips: [DemoChip] = [
        DemoChip(id: "P001", qid: "DEMO-10001", fullNameEn: "Fatima Al-Demo", fullNameAr: "فاطمة التجريبية"),
        DemoChip(id: "P002", qid: "DEMO-10002", fullNameEn: "Ahmed Al-Demo", fullNameAr: "أحمد التجريبي"),
        DemoChip(id: "P003", qid: "DEMO-10003", fullNameEn: "Ravi Demo", fullNameAr: "رافي"),
    ]

    /// `Attempt` in Login.tsx: what was sent, so a retry sends the same.
    private struct Attempt: Equatable {
        let qid: String
        let otp: String
        /// The chip's patient id, or nil for the form.
        let chip: String?
    }

    private struct Failure {
        let error: any Error
        let attempt: Attempt

        var code: String? { (error as? ClinicError)?.code }
    }

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @State private var qid = ""
    @State private var otp = ""
    /// `form` or a chip's id while a sign-in is out.
    @State private var busy: String?
    @State private var failed: Failure?
    /// Bumped on a field error, so the haptic fires on the same change as the message.
    @State private var fieldErrors = 0
    @State private var chipTaps = 0

    private var canSubmit: Bool {
        busy == nil && !clean(qid).isEmpty && !clean(otp).isEmpty
    }

    var body: some View {
        PatientScaffold(title: lang.t("login.title")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                chipSection
                form
                    .padding(.top, DS.Space.m)
                if let failed, failed.code != "unknown_qid", failed.code != "invalid_otp" {
                    ErrorBlock(message: errorText(failed.error, strings: .bundled, lang: lang)) {
                        Task { await attempt(failed.attempt) }
                    }
                    .accessibilityIdentifier("login-error")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-login")
        }
        .sensoryFeedback(DS.Haptic.failed, trigger: fieldErrors)
        .sensoryFeedback(DS.Haptic.select, trigger: chipTaps)
        #if DEBUG
        .task { await demoHook() }
        #endif
    }

    private var chipSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeading(lang.t("login.demoPatients"), role: .label)
            ChipFlow {
                ForEach(Self.chips, id: \.id) { chip in
                    Button(nameOf(chip, lang: lang)) {
                        chipTaps += 1
                        Task { await attempt(Attempt(qid: chip.qid, otp: Self.demoOtp, chip: chip.id)) }
                    }
                    .buttonStyle(ChipButtonStyle())
                    .environment(\.dsIsLoading, busy == chip.id)
                    .disabled(busy != nil)
                    .accessibilityIdentifier("chip-\(chip.id)")
                }
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            DSTextField(
                label: lang.t("login.qid"), text: $qid,
                error: failed?.code == "unknown_qid" ? message : nil, kind: .qid,
                identifier: "login-qid")
                .submitLabel(.go)
                .onSubmit { if canSubmit { submit() } }
            DSTextField(
                label: lang.t("login.otp"), text: $otp, hint: lang.t("login.otpHint"),
                error: failed?.code == "invalid_otp" ? message : nil, kind: .code,
                identifier: "login-otp")
            Button(lang.t("login.submit"), action: submit)
                .buttonStyle(PrimaryButtonStyle())
                .environment(\.dsIsLoading, busy == "form")
                .disabled(!canSubmit)
                .padding(.top, DS.Space.xs)
                .accessibilityIdentifier("login-submit")
        }
    }

    private var message: String? {
        failed.map { errorText($0.error, strings: .bundled, lang: lang) }
    }

    /// Latin digits from any keyboard, and no stray spaces, as the web's `trim()`.
    private func clean(_ text: String) -> String {
        latinDigits(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard canSubmit else { return }
        let next = Attempt(qid: clean(qid), otp: clean(otp), chip: nil)
        Task { await attempt(next) }
    }

    /// `attempt` in Login.tsx. On success the model clears the path and Home becomes the root,
    /// so this screen is gone and `busy` never needs clearing.
    private func attempt(_ next: Attempt) async {
        guard busy == nil else { return }
        busy = next.chip ?? "form"
        failed = nil
        do {
            try await model.signIn(qid: next.qid, otp: next.otp)
        } catch {
            let failure = Failure(error: error, attempt: next)
            failed = failure
            busy = nil
            if failure.code == "unknown_qid" || failure.code == "invalid_otp" { fieldErrors += 1 }
        }
    }

    #if DEBUG
    private func demoHook() async {
        guard DemoAccount.once("login") else { return }
        if let typed = DemoAccount.qid { qid = typed }
        if let typed = DemoAccount.otp { otp = typed }
        switch DemoAccount.loginTap {
        case "form"?:
            submit()
        case let id?:
            if let chip = Self.chips.first(where: { $0.id == id }) {
                await attempt(Attempt(qid: chip.qid, otp: Self.demoOtp, chip: chip.id))
            }
        case nil:
            break
        }
    }
    #endif
}

/// A demo patient on a chip: named in both languages, so `nameOf` reads it with no request.
private struct DemoChip: NamedPerson {
    let id: String
    let qid: String
    let fullNameEn: String
    let fullNameAr: String
}
