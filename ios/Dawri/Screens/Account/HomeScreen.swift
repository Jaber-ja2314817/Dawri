import DawriCore
import SwiftUI

/// S03. Do I have a visit open, and how do I start one? The port of
/// frontend/src/pages/patient/Home.tsx. The list rules are DawriCore's `VisitRules`.
struct HomeScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HomeContent(model: model)
    }
}

/// The screen itself, with its visit list made once from the model.
private struct HomeContent: View {
    let model: AppModel

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var visits: VisitList
    /// Set once a list has landed, so a reload keeps the open visits on screen.
    @State private var hasRows = false
    @State private var rowTaps = 0

    init(model: AppModel) {
        self.model = model
        _visits = State(initialValue: VisitList(model: model))
    }

    private var openRows: [VisitRow] {
        VisitRules.openVisits(visits.rows, now: Date())
    }

    /// `showOpen` in Home.tsx, except that a reload in progress keeps what was there.
    private var showsOpen: Bool {
        let landed = visits.state == .ready || (visits.state == .loading && hasRows)
        return landed && !openRows.isEmpty
    }

    var body: some View {
        PatientScaffold(title: nil) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                titleRow
                if model.showsDemoReset {
                    Notice(lang.t("home.demoReset"))
                        .accessibilityIdentifier("home-demo-reset")
                }
                if showsOpen, let me = model.me {
                    openSection(me)
                }
                record
                startButton
                if visits.state == .failed {
                    ErrorBlock(message: errorText(visits.error ?? ClinicError.network, strings: .bundled, lang: lang)) {
                        Task { await visits.retry() }
                    }
                    .accessibilityIdentifier("home-visits-error")
                }
                quietRow
                    .padding(.top, DS.Space.m)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-home")
        }
        .refreshable {
            let model = model
            let visits = visits
            await withDiscardingTaskGroup { group in
                group.addTask { await model.reloadMe() }
                group.addTask { await visits.load() }
            }
        }
        // The stack root stays mounted under everything pushed on it, so the list is read on
        // every appear, and again whenever S06 closes, which does not refire `onAppear`.
        .onAppear { reload() }
        .onChange(of: model.homeRefresh) { reload() }
        .onChange(of: visits.state) { _, state in
            if state == .ready { hasRows = true }
        }
        .sensoryFeedback(DS.Haptic.select, trigger: rowTaps)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                SettingsGear()
            }
        }
    }

    private func reload() {
        let model = model
        let visits = visits
        // Unstructured, so pushing a screen over this one cannot cancel a read halfway.
        Task {
            #if DEBUG
            await DemoAccount.freshClinic(model)
            #endif
            await visits.load()
        }
    }

    // Title

    /// The name with the demo pill on the same row, or the pill under it at accessibility sizes.
    private var titleRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.m))
        return layout {
            if let patient = model.patient {
                ScreenTitle(nameOf(patient, lang: lang))
                    .accessibilityIdentifier("home-name")
            } else {
                SkeletonBar(width: 180, height: 24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Pill(lang.t("home.demoData"), tone: .neutral)
        }
    }

    // Open visits

    private func openSection(_ me: Me) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SectionHeading(lang.t("home.openVisits"), role: .label)
            Card(flush: true) {
                VStack(spacing: 0) {
                    ForEach(Array(openRows.enumerated()), id: \.element.visitId) { index, row in
                        Button {
                            rowTaps += 1
                            open(row)
                        } label: {
                            ListRow(
                                title: personName(row, me: me),
                                subtitle: row.centre.map { centreName($0, lang: lang) },
                                pill: Pill(
                                    lang.t("status.\(row.status.rawValue)"),
                                    tone: PillTone(VisitRules.homeTone(row.status))),
                                showsRule: index > 0)
                        }
                        .buttonStyle(ListRowButtonStyle())
                        .accessibilityIdentifier("open-visit")
                    }
                }
            }
        }
    }

    private func personName(_ row: VisitRow, me: Me) -> String {
        let people = [me.patient] + me.dependents
        return people.first { $0.id == row.patientId }.map { nameOf($0, lang: lang) } ?? ""
    }

    /// Today's emergency opens S06 at once. Anything else goes through its gate.
    private func open(_ row: VisitRow) {
        switch VisitRules.openAction(row) {
        case .emergency(let visitId):
            model.showEmergency(visitId: visitId, redFlag: false)
        case .visit(let visitId):
            model.enterVisit(visitId)
        }
    }

    // Record

    @ViewBuilder
    private var record: some View {
        if model.meState == .failed {
            ErrorBlock(message: errorText(model.meError ?? ClinicError.network, strings: .bundled, lang: lang)) {
                Task { await model.reloadMe() }
            }
            .accessibilityIdentifier("home-me-error")
        } else if let me = model.me {
            Card(flush: true) {
                VStack(spacing: 0) {
                    KeyValueRow(
                        label: lang.t("home.registeredCentre"),
                        value: centreName(me.patient.registeredCentre, lang: lang), showsRule: false)
                    KeyValueRow(label: lang.t("home.allergies")) {
                        allergies(me.patient.allergies)
                    }
                    .accessibilityIdentifier("home-allergies")
                }
            }
            // A container, so the identifier stays here and the rows keep their own.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("home-record")
        } else {
            SkeletonBar(height: 90)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: lang.t("common.loading")))
                .accessibilityIdentifier("home-loading")
        }
    }

    @ViewBuilder
    private func allergies(_ allergies: [String]) -> some View {
        if allergies.isEmpty {
            Text(verbatim: lang.t("home.noAllergies"))
                .foregroundStyle(DS.Color.muted)
        } else {
            HStack(spacing: DS.Space.xs) {
                ForEach(allergies, id: \.self) { allergy in
                    Pill(
                        term(allergy),
                        tone: VisitRules.isFlaggedAllergy(allergy) ? .warning : .neutral)
                }
            }
        }
    }

    /// `recordTerm`, with the web's `first-letter:uppercase` in English.
    private func term(_ allergy: String) -> String {
        let text = Strings.bundled.recordTerm(allergy, lang: lang)
        return lang == .en ? text.prefix(1).uppercased() + text.dropFirst() : text
    }

    // Actions

    /// Primary with nothing open. With an open visit the row is the next step, so this steps back.
    @ViewBuilder
    private var startButton: some View {
        let button = Button(lang.t("home.start")) {
            if let me = model.me { model.open(checkInRoute(me)) }
        }
        .disabled(model.me == nil)
        .accessibilityIdentifier("home-start")
        if showsOpen {
            button.buttonStyle(SecondaryButtonStyle())
        } else {
            button.buttonStyle(PrimaryButtonStyle())
        }
    }

    private var quietRow: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs))
            : AnyLayout(HStackLayout(alignment: .center, spacing: DS.Space.m))
        return layout {
            Button(lang.t("home.history")) {
                model.open(.history)
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("home-history")
            if !typeSize.isAccessibilitySize { Spacer(minLength: DS.Space.m) }
            Button(lang.t("home.logout")) {
                model.signOut()
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("home-logout")
        }
    }
}

/// The gear in `.topBarLeading`, as on S01: Settings is reachable from both stack roots.
struct SettingsGear: View {
    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang

    var body: some View {
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
