#if DEBUG
import DawriCore
import SwiftUI

/// Every component of iOS Design section 12, a page at a time so each fits one screenshot.
/// `-demoScreen gallery -demoPage <1...12>`. With no page it shows them all, to scroll through.
/// Page 10 is `ScaffoldSlots`. Pages 11 and 12 are the rest of the chat's states.
struct ComponentGallery: View {
    @Environment(\.lang) private var lang
    @State private var qid = "DEMO-10001"
    @State private var code = "0000"
    @State private var server = "http://192.168.1.20:8100"
    @State private var plain = ""
    @State private var draft = ""
    @State private var draftFilled = "حرارة وكحة من 3 أيام"
    @FocusState private var focus: Bool
    @FocusState private var otherFocus: Bool

    var body: some View {
        if DemoLaunch.current?.galleryPage == 10 {
            ScaffoldSlots()
        } else {
            pages
        }
    }

    private var pages: some View {
        PatientScaffold {
            let page = DemoLaunch.current?.galleryPage
            if page == nil || page == 1 { filledButtons }
            if page == nil || page == 2 { otherButtons }
            if page == nil || page == 3 { rows }
            if page == nil || page == 4 { blocks }
            if page == nil || page == 5 { fields }
            if page == nil || page == 6 { ticket }
            if page == nil || page == 7 { smallThings }
            if page == nil || page == 8 { chat }
            if page == nil || page == 9 { voice }
            if page == nil || page == 11 { voiceMore }
            if page == nil || page == 12 { chatMore }
        }
    }

    private func name(_ text: String) -> some View {
        Text(verbatim: text)
            .dsText(.caption)
            .foregroundStyle(DS.Color.muted)
            .environment(\.layoutDirection, .leftToRight)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var filledButtons: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("PrimaryButtonStyle: rest, loading, disabled")
            Button(lang.t("home.start")) {}.buttonStyle(PrimaryButtonStyle())
            Button(lang.t("home.start")) {}.buttonStyle(PrimaryButtonStyle()).dsLoading(true)
            Button(lang.t("home.start")) {}.buttonStyle(PrimaryButtonStyle()).disabled(true)
            name("SecondaryButtonStyle: rest, disabled")
            Button(lang.t("complete.history")) {}.buttonStyle(SecondaryButtonStyle())
            Button(lang.t("complete.history")) {}.buttonStyle(SecondaryButtonStyle()).disabled(true)
            name("DestructiveButtonStyle")
            Button(lang.t("settings.reset")) {}.buttonStyle(DestructiveButtonStyle())
            name("QuietButtonStyle: plain, underlined")
            HStack(spacing: DS.Space.xl) {
                Button(lang.t("home.logout")) {}.buttonStyle(QuietButtonStyle())
                Button(lang.t("common.retry")) {}.buttonStyle(QuietButtonStyle(underlined: true))
            }
        }
    }

    private var otherButtons: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("EmergencyCallButtonStyle, LanguageToggle(.emergency), on the field")
            VStack(alignment: .trailing, spacing: DS.Space.s) {
                LanguageToggle(tone: .emergency)
                Button {} label: {
                    Label {
                        Text(verbatim: lang.t("emergency.call"))
                    } icon: {
                        Image(systemName: "phone.fill")
                    }
                }
                .buttonStyle(EmergencyCallButtonStyle())
            }
            .padding(DS.Space.m)
            .background(DS.Emergency.field)
            name("ChipButtonStyle in ChipFlow")
            ChipFlow {
                Button("Fatima Al-Demo") {}.buttonStyle(ChipButtonStyle())
                Button("Ahmed Al-Demo") {}.buttonStyle(ChipButtonStyle())
                Button("Ravi Demo") {}.buttonStyle(ChipButtonStyle())
            }
            name("DemoNextStepButton: rest, busy")
            DemoNextStepButton {}
            DemoNextStepButton(isBusy: true) {}
            name("ScreenTitle")
            ScreenTitle(lang.t("who.title"))
            name("ProductLockup")
            ProductLockup()
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("Card flush: ListRow, Pill")
            Card(flush: true) {
                VStack(spacing: 0) {
                    ListRow(
                        title: lang.t("who.me"), subtitle: lang.t("who.age", ["age": 34]),
                        pill: Pill(lang.t("status.in_triage"), tone: .neutral), showsRule: false)
                    ListRow(
                        title: lang.t("home.history"),
                        subtitle: formatDate("2026-11-07T09:00:00.901593+00:00", lang: lang),
                        pill: Pill(lang.t("status.completed"), tone: .positive))
                    ListRow(title: lang.t("status.expired"), showsChevron: false)
                }
            }
            name("Card flush: KeyValueRow, Measure, Dash, a real zero")
            Card(flush: true) {
                VStack(spacing: 0) {
                    KeyValueRow(label: lang.t("ticket.peopleAhead"), value: "0", style: .stat, showsRule: false)
                    KeyValueRow(label: lang.t("ticket.estimatedWait"), style: .stat) {
                        Measure(value: 12, unit: lang.t("centre.unitMin"))
                    }
                    KeyValueRow(label: lang.t("centre.distance"), style: .stat) {
                        Measure(value: 7.2, unit: lang.t("centre.unitKm"))
                    }
                    KeyValueRow(label: lang.t("ticket.goTo"), style: .stat) { Dash() }
                    KeyValueRow(label: lang.t("home.registeredCentre"), value: "Al Wakra Health Centre")
                }
            }
        }
    }

    private var blocks: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("Pill")
            ChipFlow {
                Pill(lang.t("status.completed"), tone: .positive)
                Pill(lang.t("status.redirected_emergency"), tone: .negative)
                Pill(lang.t("status.expired"), tone: .warning)
                Pill(lang.t("home.demoData"), tone: .neutral)
            }
            name("Notice")
            Notice(lang.t("home.demoReset"))
            name("ErrorBlock")
            ErrorBlock(message: lang.t("error.network")) {}
            name("SkeletonBar: text, card")
            SkeletonBar(width: 180, height: 20)
            SkeletonBar(height: 64)
            name("PatientFooter")
            PatientFooter()
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            name("DSTextField: qid, code with hint, error, address, disabled, placeholder")
            DSTextField(label: lang.t("login.qid"), text: $qid, kind: .qid)
            DSTextField(
                label: lang.t("login.otp"), text: $code, hint: lang.t("login.otpHint"), kind: .code)
            DSTextField(
                label: lang.t("login.qid"), text: $plain, error: lang.t("error.unknown_qid"), kind: .qid)
            DSTextField(label: lang.t("settings.server"), text: $server, kind: .address)
            DSTextField(label: lang.t("chat.input.label"), text: $qid).disabled(true)
            DSTextField(
                label: lang.t("chat.input.label"), text: $plain,
                placeholder: lang.t("chat.input.placeholder"))
        }
    }

    private var ticket: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("TicketNumberBlock with StageTrack, next step")
            TicketNumberBlock(number: "T-014", stage: .triage)
            TicketNumberBlock(number: "D-GP-023", stage: .doctor)
            TicketNumberBlock(number: nil, stage: .pharmacy)
            name("StageTrack compact, no current stage")
            Card {
                VStack(spacing: DS.Space.m) {
                    StageTrack(stage: .pharmacy, style: .compact)
                    StageTrack(stage: nil)
                }
            }
        }
    }

    private var smallThings: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("CountdownText")
            Card { CountdownText(expiresAt: Timestamp.string(from: .now.addingTimeInterval(44 * 60 + 59))) }
            Card { CountdownText(expiresAt: nil) }
            name("WaitBadge: rest, selected, missing")
            HStack(spacing: DS.Space.s) {
                WaitBadge(minutes: 12)
                WaitBadge(minutes: 35, selected: true)
                WaitBadge(minutes: nil)
            }
            name("StarRating: open, busy, sent")
            StarRating(rating: nil) { _ in }
            StarRating(rating: nil, isBusy: true) { _ in }
            StarRating(rating: 5)
            name("ChatBubble, ThinkingBubble")
            ChatBubble(role: .assistant, text: lang.t("chat.summary.check"))
            ChatBubble(role: .user, text: "I have a fever since 3 days")
            ThinkingBubble()
        }
    }

    private var chat: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("SummaryCard: unsent text, Yes disabled")
            SummaryCard(
                service: .gp, summary: "fever and cough, 3 days, severity 6/10", hasUnsent: true,
                onYes: {}, onChange: {})
            name("SummaryCard: ready")
            SummaryCard(
                service: .gp, summary: "حرارة وكحة، 3 أيام، الشدة 6 من 10", onYes: {}, onChange: {})
        }
    }

    private var chatMore: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("SummaryCard: confirming, then a failed Yes")
            SummaryCard(
                service: .dental, summary: "toothache, 2 days", isConfirming: true, onYes: {},
                onChange: {})
            SummaryCard(
                service: .gp, summary: "fever, 3 days", confirmError: lang.t("error.network"),
                onYes: {}, onChange: {})
        }
    }

    private var voice: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("Composer: idle, empty")
            Composer(text: $draft, focus: $focus, onSend: {}, onMic: {})
                .padding(.horizontal, -DS.Space.l)
            name("Composer: with text, and a voice error")
            Composer(
                text: $draftFilled, focus: $otherFocus,
                voiceError: lang.t("voice.unavailableOnDevice"),
                voice: .mic(secondary: true, disabled: false), onSend: {}, onMic: {})
                .padding(.horizontal, -DS.Space.l)
            name("Composer: listening, ListeningPanel")
            Composer(
                text: $draft, focus: $focus, isBusy: true,
                voice: .listening(seconds: 12, partial: "حرارة وكحة"), onSend: {}, onMic: {})
                .padding(.horizontal, -DS.Space.l)
        }
    }

    private var voiceMore: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            name("Composer: transcribing, read-only while thinking")
            Composer(
                text: $draftFilled, focus: $otherFocus, isReadOnly: true, isBusy: true,
                voice: .working(key: "voice.transcribing"), onSend: {}, onMic: {})
                .padding(.horizontal, -DS.Space.l)
            name("TranscriptConfirmPanel")
            TranscriptConfirmPanel(
                text: $draftFilled, focus: $otherFocus, onSend: {}, onRetry: {}, onClear: {})
                .padding(.horizontal, -DS.Space.l)
        }
    }
}

/// `PatientScaffold`'s slots with something in each, because no screen fills all of them yet.
private struct ScaffoldSlots: View {
    @Environment(\.lang) private var lang
    @State private var position = ScrollPosition(edge: .top)
    @State private var text = ""

    var body: some View {
        PatientScaffold(footer: .pinned, scrollPosition: $position) {
            ForEach(0..<30) { row in
                Text(verbatim: String(row))
                    .dsText(.body)
                    .foregroundStyle(DS.Color.ink)
                    .accessibilityIdentifier("slots-row-\(row)")
            }
        } pinnedTop: {
            Button("end") { position.scrollTo(edge: .bottom) }
                .accessibilityIdentifier("slots-top")
        } pinnedBottom: {
            DSTextField(label: lang.t("settings.server"), text: $text)
                .padding(DS.Space.m)
                .accessibilityIdentifier("slots-bottom")
        }
    }
}
#endif
