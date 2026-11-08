import DawriCore
import Observation
import SwiftUI

/// S11. What do I do next, and how do I take my medicines? The port of
/// frontend/src/pages/patient/Complete.tsx and features/ticket/Rating.tsx. Medicines are the
/// clinic's own plain-language lines in the screen's language, never retyped here.
struct CompleteScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model

    var body: some View {
        CompleteContent(visit: visit, watcher: watcher, model: model)
    }
}

/// `Rating` in Rating.tsx: a rating sent once, `already_rated` read again, any other failure
/// shown under the stars.
@MainActor
@Observable
final class RatingModel {
    private(set) var sent: Int?
    private(set) var isBusy = false
    private(set) var failure: (any Error)?

    @ObservationIgnored private let service: any ClinicService
    @ObservationIgnored private let visitId: String

    init(service: any ClinicService, visitId: String) {
        self.service = service
        self.visitId = visitId
    }

    /// Returns whether the visit should be read again.
    func rate(_ stars: Int) async -> Bool {
        guard !isBusy else { return false }
        isBusy = true
        failure = nil
        defer { isBusy = false }
        do {
            sent = try await service.rateVisit(visitId: visitId, stars: stars).rating
            return true
        } catch {
            if TicketRules.ratingNeedsRefetch(error) { return true }
            failure = error
            return false
        }
    }
}

private struct CompleteContent: View {
    let visit: Visit
    let watcher: VisitWatcher
    let model: AppModel

    @Environment(\.lang) private var lang
    @State private var rating: RatingModel
    @State private var completed = 0
    @State private var position = ScrollPosition(edge: .top)

    init(visit: Visit, watcher: VisitWatcher, model: AppModel) {
        self.visit = visit
        self.watcher = watcher
        self.model = model
        _rating = State(initialValue: RatingModel(service: model.service, visitId: visit.visitId))
    }

    private var shownRating: Int? { visit.rating ?? rating.sent }

    var body: some View {
        PatientScaffold(scrollPosition: $position) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                heading
                medicines
                followUp
                rate
                actions
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-complete")
        }
        .navigationTitle(lang.t("complete.title"))
        .sensoryFeedback(DS.Haptic.visitComplete, trigger: completed)
        .onAppear {
            // Only a visit that moved on to this screen, once. Opened from History, it is quiet.
            if model.arrivedByMovingOn(.visit(id: visit.visitId, screen: .complete)) {
                completed += 1
            }
        }
        #if DEBUG
        .task { await demoHooks() }
        #endif
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Image(systemName: "checkmark")
                    .dsText(.screenTitle)
                    .foregroundStyle(DS.Color.positive)
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("complete-check")
                ScreenTitle(lang.t("complete.title"))
            }
            if let centre = visit.centre {
                Text(verbatim: centreName(centre, lang: lang))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.muted)
                    .multilineTextAlignment(.leading)
            }
        }
    }

    private var medicines: some View {
        let lines = TicketRules.medicines(visit, lang: lang)
        return Card {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SectionHeading(lang.t("complete.medicines"))
                if lines.isEmpty {
                    Text(verbatim: lang.t("complete.noMedicines"))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.muted)
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("no-medicines")
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        medicine(line)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("medicines")
    }

    private func medicine(_ line: MedicineLine) -> some View {
        let split = TicketRules.splitLine(line)
        return VStack(alignment: .leading, spacing: DS.Space.xxs) {
            Text(verbatim: Bidi.auto(split.heading))
                .dsText(.bodyStrong)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(verbatim: Bidi.auto(split.directions))
                .dsText(.secondary)
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .multilineTextAlignment(.leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: "\(split.heading). \(split.directions)"))
        .accessibilityIdentifier("medicine")
    }

    private var followUp: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SectionHeading(lang.t("complete.followUp"))
                Text(verbatim: Bidi.fill("complete.followUpLine", ["phone": 999], lang: lang))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: lang.t("complete.followUpLine", ["phone": 999])))
                    .accessibilityIdentifier("follow-up")
            }
        }
    }

    private var rate: some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                SectionHeading(lang.t("complete.rate"))
                if let shown = shownRating {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        StarRating(rating: shown)
                        Text(verbatim: "\(lang.t("complete.thanks")) (\(Bidi.ltr("\(shown)/5")))")
                            .dsText(.secondary)
                            .foregroundStyle(DS.Color.muted)
                            .multilineTextAlignment(.leading)
                            .accessibilityLabel(Text(verbatim: "\(lang.t("complete.thanks")), \(lang.t("complete.stars", ["stars": shown]))"))
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("rating-read-only")
                } else {
                    StarRating(rating: nil, isBusy: rating.isBusy) { stars in
                        Task { await send(stars) }
                    }
                    if let failure = rating.failure {
                        Text(verbatim: errorText(failure, strings: .bundled, lang: lang))
                            .dsText(.secondary)
                            .foregroundStyle(DS.Color.negative)
                            .multilineTextAlignment(.leading)
                            .accessibilityIdentifier("rating-error")
                            .onAppear {
                                AccessibilityNotification.Announcement(
                                    errorText(failure, strings: .bundled, lang: lang)
                                ).post()
                            }
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button(lang.t("complete.home")) {
                model.open(.home)
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("complete-home")
            Button(lang.t("complete.history")) {
                model.open(.history)
            }
            .buttonStyle(QuietButtonStyle())
            .accessibilityIdentifier("complete-history")
            if let number = visit.ticket?.number {
                // No hue: the visit is over.
                Text(verbatim: "\(lang.t("complete.finalTicket")) \(Bidi.ltr(number))")
                    .dsText(.caption, monoDigits: true)
                    .foregroundStyle(DS.Color.muted)
                    .accessibilityLabel(Text(verbatim: "\(lang.t("complete.finalTicket")) \(number)"))
                    .accessibilityIdentifier("final-ticket")
            }
        }
    }

    private func send(_ stars: Int) async {
        if await rating.rate(stars) {
            await watcher.refetch()
        } else if let failure = rating.failure {
            model.sessionEnded(by: failure)
        }
    }

    #if DEBUG
    private func demoHooks() async {
        if let stars = DemoVisit.rating, shownRating == nil, DemoVisit.once("rate") {
            await send(stars)
        }
        if DemoVisit.scrollsToEnd {
            try? await Task.sleep(for: .milliseconds(300))
            position.scrollTo(edge: .bottom)
        }
    }
    #endif
}
