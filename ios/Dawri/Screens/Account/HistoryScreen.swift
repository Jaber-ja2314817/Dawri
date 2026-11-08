import DawriCore
import SwiftUI

/// S12. What visits have I had? The port of frontend/src/pages/patient/History.tsx. Which rows
/// open, and to where, is DawriCore's `VisitRules`.
struct HistoryScreen: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HistoryContent(model: model)
    }
}

private struct HistoryContent: View {
    let model: AppModel

    @Environment(\.lang) private var lang
    @State private var visits: VisitList
    @State private var rowTaps = 0

    init(model: AppModel) {
        self.model = model
        _visits = State(initialValue: VisitList(model: model))
    }

    var body: some View {
        PatientScaffold(title: lang.t("history.title")) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                content
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-history")
        }
        .refreshable { await visits.load() }
        .task {
            #if DEBUG
            await DemoAccount.freshClinic(model)
            #endif
            await visits.load()
        }
        .sensoryFeedback(DS.Haptic.select, trigger: rowTaps)
    }

    /// A refresh keeps the rows already on screen. The first read shows the card-sized bar.
    @ViewBuilder
    private var content: some View {
        if visits.state == .failed {
            ErrorBlock(message: errorText(visits.error ?? ClinicError.network, strings: .bundled, lang: lang)) {
                Task { await visits.retry() }
            }
            .accessibilityIdentifier("history-error")
        } else if !visits.rows.isEmpty {
            Card(flush: true) {
                VStack(spacing: 0) {
                    ForEach(Array(visits.rows.enumerated()), id: \.element.visitId) { index, row in
                        historyRow(row, showsRule: index > 0)
                    }
                }
            }
        } else if visits.state == .loading {
            SkeletonBar(height: 168)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: lang.t("common.loading")))
                .accessibilityIdentifier("history-loading")
        } else {
            Text(verbatim: lang.t("history.empty"))
                .dsText(.body)
                .foregroundStyle(DS.Color.muted)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("history-empty")
            Button(lang.t("home.start")) {
                if let me = model.me { model.open(checkInRoute(me)) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.me == nil)
            .accessibilityIdentifier("history-start")
        }
    }

    /// `Row` in History.tsx. A row that opens is a button with a chevron; the rest keep their
    /// height and have neither.
    @ViewBuilder
    private func historyRow(_ row: VisitRow, showsRule: Bool) -> some View {
        let item = ListRow(
            title: row.centre.map { centreName($0, lang: lang) } ?? lang.t("history.noCentre"),
            subtitle: detail(row),
            pill: Pill(
                lang.t("status.\(row.status.rawValue)"),
                tone: PillTone(VisitRules.historyTone(row.status))),
            showsChevron: VisitRules.historyRoute(row) != nil,
            showsRule: showsRule)
        if let route = VisitRules.historyRoute(row) {
            Button {
                rowTaps += 1
                // A push, so Back from the visit returns here.
                model.open(route)
            } label: {
                item
            }
            .buttonStyle(ListRowButtonStyle())
            .accessibilityIdentifier("history-row")
        } else {
            item
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("history-row")
        }
    }

    /// Date, service and the dependent's name, joined with ` · `.
    private func detail(_ row: VisitRow) -> String {
        let dependent = model.me?.dependents.first { $0.id == row.patientId }
        return VisitRules.detailLine([
            formatDate(row.createdAt, lang: lang),
            row.service.map { lang.t("service.\($0.rawValue)") },
            dependent.map { nameOf($0, lang: lang) },
        ])
    }
}
