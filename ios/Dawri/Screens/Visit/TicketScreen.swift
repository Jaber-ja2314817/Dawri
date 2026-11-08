import DawriCore
import SwiftUI

/// S10. What is my number, and when am I called? The port of
/// frontend/src/pages/patient/Ticket.tsx. The screen is watched, not worked: the number, the
/// stage and the figures change in place as the visit moves, and the gate swaps the screen for
/// S11 when it is done.
///
/// The hue goes on the number and the current stage only. Demo: next step exists only when the
/// service is the demo clinic, says Demo in both languages, and moves the visit through the same
/// engine as the clinic's own clock, which keeps running beside it.
struct TicketScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// `usePollingSettled`: true once updates have come by polling for a moment.
    @State private var slow = false
    @State private var stepping = false
    /// The demo clinic had a step but someone real stands ahead, so nothing moved.
    @State private var demoWaited = false
    /// Bumped once when the visit moved on to this screen at arrival, so the haptic plays on the
    /// frame the number appears, and not when the visit is opened from Home.
    @State private var activated = 0

    private var ticket: Ticket? { TicketRules.shownTicket(visit) }

    private var counter: String? {
        visit.goTo.map { lang == .ar ? $0.counterAr : $0.counter }
    }

    private var isCalled: Bool { ticket?.state == .called }

    var body: some View {
        PatientScaffold(title: visit.centre.map { centreName($0, lang: lang) } ?? lang.t("screen.ticket")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if let dependent = TicketRules.dependent(of: visit, in: model.me) {
                    Text(verbatim: lang.t("ticket.forPerson", ["name": Bidi.auto(nameOf(dependent, lang: lang))]))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.muted)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("visit-for")
                }
                TicketNumberBlock(number: ticket?.number, stage: visit.stage)
                if let ticket {
                    detail(ticket)
                }
                if let driver = model.demoDriver {
                    demo(driver)
                }
                if slow {
                    freshness
                }
            }
            .animation(DS.Motion.resolved(DS.Motion.number, reduceMotion: reduceMotion), value: ticket?.state)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-ticket")
        }
        .refreshable { await watcher.refetch() }
        .sensoryFeedback(DS.Haptic.activated, trigger: activated)
        .sensoryFeedback(DS.Haptic.stageChange, trigger: visit.stage)
        .onAppear {
            if model.arrivedByMovingOn(.visit(id: visit.visitId, screen: .ticket)) {
                activated += 1
            }
        }
        .sensoryFeedback(DS.Haptic.called, trigger: isCalled) { _, now in now }
        .onChange(of: isCalled) { _, now in
            if now { announceCall() }
        }
        .onChange(of: visit) { demoWaited = false }
        #if DEBUG
        .task {
            if DemoVisit.steps, DemoVisit.once("step"), let driver = model.demoDriver { await step(driver) }
        }
        #endif
        .task(id: watcher.live) {
            slow = false
            guard watcher.live == .polling else { return }
            try? await Task.sleep(for: TicketRules.pollingNoticeDelay)
            if !Task.isCancelled { slow = true }
        }
    }

    // The figures

    @ViewBuilder
    private func detail(_ ticket: Ticket) -> some View {
        if ticket.state == .called {
            Text(verbatim: lang.t("ticket.goNow", ["counter": Bidi.auto(counter ?? "")]))
                .dsText(.screenTitle)
                .foregroundStyle(DS.Color.primaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(DS.Space.l)
                .background(
                    DS.Color.primaryFill,
                    in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .transition(change)
                .accessibilityLabel(Text(verbatim: lang.t("ticket.goNow", ["counter": counter ?? ""])))
                .accessibilityIdentifier("ticket-called")
        }
        if ticket.state == .serving {
            Card {
                Text(verbatim: lang.t("ticket.withTeam"))
                    .dsText(.bodyStrong)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .transition(change)
            .accessibilityIdentifier("ticket-serving")
        }
        let rows = TicketRules.rows(for: ticket.state)
        if !rows.isEmpty {
            Card(flush: true) {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element) { index, row in
                        self.row(row, ticket: ticket, showsRule: index > 0)
                    }
                }
            }
        }
    }

    /// Opacity and a 6 pt rise, or a cross-fade with Reduce Motion.
    private var change: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(y: 6))
    }

    /// Each row is one VoiceOver element, so the web's test id goes on the row.
    @ViewBuilder
    private func row(_ row: TicketRules.TicketRow, ticket: Ticket, showsRule: Bool) -> some View {
        switch row {
        case .peopleAhead:
            KeyValueRow(label: lang.t("ticket.peopleAhead"), style: .stat, showsRule: showsRule) {
                Count(value: ticket.peopleAhead)
                    .contentTransition(counting(ticket.peopleAhead))
                    .animation(DS.Motion.resolved(DS.Motion.number, reduceMotion: reduceMotion), value: ticket.peopleAhead)
            }
            .accessibilityIdentifier("people-ahead")
        case .estimatedWait:
            KeyValueRow(label: lang.t("ticket.estimatedWait"), style: .stat, showsRule: showsRule) {
                Measure(value: ticket.estWaitMin, unit: lang.t("centre.unitMin"))
                    .contentTransition(counting(ticket.estWaitMin))
                    .animation(DS.Motion.resolved(DS.Motion.number, reduceMotion: reduceMotion), value: ticket.estWaitMin)
            }
            .accessibilityIdentifier("est-wait")
        case .goTo:
            KeyValueRow(label: lang.t("ticket.goTo"), style: .stat, showsRule: showsRule) {
                if let counter {
                    Text(verbatim: Bidi.auto(counter))
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(Text(verbatim: counter))
                } else {
                    Dash()
                }
            }
            .accessibilityIdentifier("go-to")
        }
    }

    private func counting(_ value: Int?) -> ContentTransition {
        reduceMotion ? .opacity : .numericText(value: Double(value ?? 0))
    }

    // Demo

    @ViewBuilder
    private func demo(_ driver: any DemoDriving) -> some View {
        DemoNextStepButton(isBusy: stepping) {
            Task { await step(driver) }
        }
        if demoWaited {
            Text(verbatim: lang.t("demo.waiting"))
                .dsText(.secondary)
                .foregroundStyle(DS.Color.muted)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("demo-waiting")
        }
    }

    private func step(_ driver: any DemoDriving) async {
        guard !stepping else { return }
        stepping = true
        defer { stepping = false }
        do {
            let outcome = try await driver.demoNextStep(visitId: visit.visitId)
            await watcher.refetch()
            demoWaited = outcome == .waiting
        } catch {
            model.sessionEnded(by: error)
            await watcher.refetch()
        }
    }

    // Freshness

    /// `Freshness` in Ticket.tsx, once polling has lasted a moment. Never while live.
    private var freshness: some View {
        var line = lang.t("ticket.slower")
        if let updated = watcher.updatedAt {
            line += " \(lang.t("ticket.updatedAt")) \(Bidi.ltr(TicketRules.dohaClock(updated)))"
        }
        return Text(verbatim: line)
            .dsText(.caption, monoDigits: true)
            .foregroundStyle(DS.Color.muted)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .accessibilityLabel(Text(verbatim: Bidi.strip(line)))
            .accessibilityIdentifier("freshness")
    }

    // VoiceOver

    /// Read out at once, ahead of anything else queued, because it means go now.
    private func announceCall() {
        var text = AttributedString(lang.t("ticket.goNow", ["counter": counter ?? ""]))
        text.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(text).post()
    }
}
