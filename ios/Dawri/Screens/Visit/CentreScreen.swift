import DawriCore
import Observation
import SwiftUI

/// S08. Where should I go, and how long will it take? The port of
/// frontend/src/pages/patient/Centre.tsx and features/map/CentreList.tsx. The rules are
/// DawriCore's `TicketRules`. The map is `CentreMap`, on MapKit.
struct CentreScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model

    var body: some View {
        CentreContent(visit: visit, watcher: watcher, model: model)
    }
}

/// `useCentres` and the screen's own state in Centre.tsx. A new load supersedes the one before
/// it, and a failed reload keeps the list on screen.
@MainActor
@Observable
final class CentreModel {
    enum Reserve {
        case reserved
        case elsewhere(TicketRules.Elsewhere)
        case failed
    }

    private(set) var list: CentreList?
    private(set) var error: (any Error)?
    private(set) var isLocating = false
    private(set) var locationFailed = false
    private(set) var isReserving = false
    private(set) var reserveError: (any Error)?
    /// The patient's pick, which outranks the clinic's default.
    private(set) var picked: String?

    @ObservationIgnored private let service: any ClinicService
    @ObservationIgnored private let location: any LocationSource
    @ObservationIgnored private let visitId: String
    @ObservationIgnored private let serviceName: String
    @ObservationIgnored private var point: LocationPoint?
    @ObservationIgnored private var request = 0

    init(service: any ClinicService, location: any LocationSource, visit: Visit) {
        self.service = service
        self.location = location
        visitId = visit.visitId
        serviceName = (visit.service ?? .gp).rawValue
    }

    func load() async {
        request += 1
        let mine = request
        error = nil
        do {
            let next = try await service.listCentres(
                service: serviceName, visitId: visitId, lat: point?.lat, lng: point?.lng)
            guard mine == request else { return }
            list = next
        } catch {
            guard mine == request, !(error is CancellationError) else { return }
            self.error = error
        }
    }

    func pick(_ centreId: String) {
        picked = centreId
        reserveError = nil
    }

    /// One reading, never watching. A refusal leaves the list as it was.
    func locate() async {
        isLocating = true
        locationFailed = false
        do {
            point = try await location.currentPoint()
            isLocating = false
            await load()
        } catch {
            isLocating = false
            locationFailed = true
        }
    }

    /// Keeps the spinner on success, because the screen is about to move on.
    func reserve(_ centreId: String) async -> Reserve {
        isReserving = true
        reserveError = nil
        do {
            _ = try await service.reserve(visitId: visitId, centreId: centreId)
            return .reserved
        } catch {
            if let elsewhere = TicketRules.elsewhere(after: error) { return .elsewhere(elsewhere) }
            reserveError = error
            isReserving = false
            return .failed
        }
    }
}

private enum CentreView: Hashable {
    case map, list
}

private struct CentreContent: View {
    let visit: Visit
    let watcher: VisitWatcher
    let model: AppModel

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var centres: CentreModel
    /// Nil until the patient chooses, so the start follows the text size: map, or the list at
    /// accessibility sizes.
    @State private var chosenView: CentreView?
    @State private var mapFailed = false
    @State private var selections = 0
    private let path: any NetworkPathProbe

    init(visit: Visit, watcher: VisitWatcher, model: AppModel) {
        self.visit = visit
        self.watcher = watcher
        self.model = model
        var location = model.features.location
        var path: any NetworkPathProbe = SystemPathProbe()
        #if DEBUG
        location = DemoVisit.location(location, service: model.service, visitId: visit.visitId)
        path = DemoVisit.pathProbe(path)
        #endif
        self.path = path
        _centres = State(
            initialValue: CentreModel(service: model.service, location: location, visit: visit))
    }

    /// Fixed under the bar at regular sizes. At accessibility sizes everything scrolls, so the
    /// controls cannot crowd out the details.
    private var pins: Bool { !typeSize.isAccessibilitySize }

    private var view: CentreView {
        if mapFailed { return .list }
        return chosenView ?? (typeSize.isAccessibilitySize ? .list : .map)
    }

    private var viewBinding: Binding<CentreView> {
        Binding(get: { view }, set: { chosenView = $0 })
    }

    var body: some View {
        PatientScaffold(title: lang.t("screen.centre"), pinsTitle: pins) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                if !pins { header }
                details
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-centre")
        } pinnedTop: {
            if pins { header }
        }
        .sensoryFeedback(DS.Haptic.select, trigger: selections)
        // The map and list picker is a picker, iOS Design section 6.4. Only a patient's choice sets it.
        .sensoryFeedback(DS.Haptic.select, trigger: chosenView)
        .task { await centres.load() }
        // Once, at entry: with no network the map would be an empty grid, so S08 is the list.
        .task {
            if await !path.hasPath() { mapFailed = true }
        }
        #if DEBUG
        .task { await demoHooks() }
        #endif
    }

    // The fixed part

    @ViewBuilder
    private var header: some View {
        if let list = centres.list, !list.centres.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Group {
                    if list.serviceFallback {
                        note("centre.gpFirst", id: "gp-first")
                    }
                    if mapFailed {
                        Notice(lang.t("centre.mapFailed"))
                            .accessibilityIdentifier("map-failed")
                    }
                    controls
                    if centres.locationFailed {
                        note("centre.locationFailed", id: "location-failed")
                    }
                }
                .padding(.horizontal, pins ? DS.Space.l : 0)
                if view == .map {
                    CentreMap(
                        centres: list.centres, selectedId: selectedId(list),
                        onSelect: select, onFail: { mapFailed = true })
                        .padding(.horizontal, pins ? 0 : -DS.Space.l)
                }
            }
            .padding(.bottom, pins ? DS.Space.m : 0)
        } else if centres.list == nil, centres.error == nil {
            loadingHeader
        }
    }

    private var controls: some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s))
            : AnyLayout(HStackLayout(spacing: DS.Space.m))
        return layout {
            if !mapFailed {
                Picker(lang.t("centre.view"), selection: viewBinding) {
                    Text(verbatim: lang.t("centre.viewMap")).tag(CentreView.map)
                    Text(verbatim: lang.t("centre.viewList")).tag(CentreView.list)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("centre-view")
            }
            if !mapFailed, !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            Button {
                Task { await centres.locate() }
            } label: {
                Label {
                    Text(verbatim: lang.t("centre.useLocation"))
                } icon: {
                    if !centres.isLocating { Image(systemName: "location") }
                }
            }
            .buttonStyle(QuietButtonStyle())
            .dsLoading(centres.isLocating)
            .accessibilityIdentifier("use-location")
        }
    }

    private func note(_ key: String, id: String) -> some View {
        Text(verbatim: lang.t(key))
            .dsText(.secondary)
            .foregroundStyle(DS.Color.muted)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(id)
    }

    /// Bars where the control row and the map will land. Labels show at once, values are bars.
    private var loadingHeader: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            SkeletonBar(width: 180, height: DS.Size.minTarget)
                .padding(.horizontal, pins ? DS.Space.l : 0)
            if !typeSize.isAccessibilitySize {
                Rectangle()
                    .fill(DS.Color.skeleton)
                    .frame(maxWidth: .infinity)
                    .modifier(CentreMapFrame())
            }
        }
        .padding(.bottom, pins ? DS.Space.m : 0)
        .accessibilityHidden(true)
    }

    // The scroll

    @ViewBuilder
    private var details: some View {
        if let list = centres.list {
            if list.centres.isEmpty {
                empty
            } else {
                if let error = centres.error {
                    // A reload failed: the list stays, with the error above it.
                    ErrorBlock(message: errorText(error, strings: .bundled, lang: lang)) {
                        Task { await centres.load() }
                    }
                    .accessibilityIdentifier("centres-error")
                }
                selectedCard(list)
                if view == .list {
                    centreList(list)
                }
                if let suggestion = list.suggestion {
                    suggestionCard(suggestion, list: list)
                }
            }
        } else if let error = centres.error {
            ErrorBlock(message: errorText(error, strings: .bundled, lang: lang)) {
                Task { await centres.load() }
            }
            .accessibilityIdentifier("centres-error")
        } else {
            SkeletonBar(height: 168)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: lang.t("common.loading")))
                .accessibilityIdentifier("centre-loading")
        }
    }

    private var empty: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(verbatim: lang.t("centre.empty"))
                .dsText(.body)
                .foregroundStyle(DS.Color.ink)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("centre-empty")
            Button(lang.t("centre.home")) {
                model.open(.home)
            }
            .buttonStyle(SecondaryButtonStyle())
            .accessibilityIdentifier("centre-home")
        }
    }

    private func selectedId(_ list: CentreList) -> String? {
        TicketRules.selectedId(picked: centres.picked, list: list)
    }

    private func select(_ centreId: String) {
        centres.pick(centreId)
        selections += 1
    }

    // The selected centre

    @ViewBuilder
    private func selectedCard(_ list: CentreList) -> some View {
        if let centre = TicketRules.selected(picked: centres.picked, list: list) {
            Card {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    // One layout that changes shape, so the heading keeps its identity as text grows.
                    let heading = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.xs))
                        : AnyLayout(HStackLayout(spacing: DS.Space.s))
                    heading { centreHeading(centre) }
                    figures(centre)
                    if let error = centres.reserveError {
                        ErrorBlock(message: errorText(error, strings: .bundled, lang: lang))
                            .accessibilityIdentifier("reserve-error")
                    }
                    Button(lang.t("centre.checkIn")) {
                        Task { await checkIn(centre.id) }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .dsLoading(centres.isReserving)
                    .accessibilityIdentifier("check-in-here")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("selected-centre")
        } else {
            Card {
                Text(verbatim: lang.t("centre.choosePrompt"))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.muted)
                    .multilineTextAlignment(.leading)
            }
            .accessibilityIdentifier("selected-centre")
        }
    }

    @ViewBuilder
    private func centreHeading(_ centre: CentreOption) -> some View {
        Text(verbatim: centreName(centre, lang: lang))
            .dsText(.section)
            .foregroundStyle(DS.Color.ink)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
        if centre.registered {
            Pill(lang.t("centre.yourCentre"), tone: .neutral)
        }
    }

    /// Wait, people ahead, and the distance once it is known. Label over value, in a row, or one
    /// under another at accessibility sizes.
    private func figures(_ centre: CentreOption) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: DS.Space.s))
            : AnyLayout(HStackLayout(alignment: .top, spacing: DS.Space.m))
        return layout {
            figure("centre.wait", id: "selected-wait") {
                Measure(value: centre.waitMin, unit: lang.t("centre.unitMin"))
            }
            figure("centre.peopleAhead", id: "selected-ahead") { Count(value: centre.peopleAhead) }
            if let distance = centre.distanceKm {
                figure("centre.distance", id: "selected-distance") {
                    Measure(value: distance, unit: lang.t("centre.unitKm"))
                }
            }
        }
    }

    private func figure(
        _ key: String, id: String, @ViewBuilder value: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(verbatim: lang.t(key))
                .dsText(.secondary)
                .foregroundStyle(DS.Color.muted)
            value()
                .dsText(.statValue)
                .foregroundStyle(DS.Color.ink)
        }
        .frame(maxWidth: typeSize.isAccessibilitySize ? nil : .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(id)
    }

    // The list

    private func centreList(_ list: CentreList) -> some View {
        let rows = TicketRules.ordered(list.centres)
        let chosen = selectedId(list)
        return Card(flush: true) {
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, centre in
                    CentreRow(
                        centre: centre, chosen: centre.id == chosen, showsRule: index > 0
                    ) {
                        select(centre.id)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: lang.t("centre.listLabel")))
        .accessibilityIdentifier("centre-list")
    }

    // The suggestion

    private func suggestionCard(_ suggestion: CentreSuggestion, list: CentreList) -> some View {
        Card {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Pill(lang.t("centre.suggestion"), tone: .neutral)
                Text(verbatim: Bidi.auto(TicketRules.reason(suggestion, lang: lang)))
                    .dsText(.secondary)
                    .foregroundStyle(DS.Color.ink)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(verbatim: TicketRules.reason(suggestion, lang: lang)))
                    .accessibilityIdentifier("suggestion-reason")
                if TicketRules.offersSuggestion(list, picked: centres.picked) {
                    Button(lang.t("centre.chooseSuggested")) {
                        select(suggestion.centreId)
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .accessibilityIdentifier("choose-suggested")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("centre-suggestion")
    }

    // Acting

    private func checkIn(_ centreId: String) async {
        switch await centres.reserve(centreId) {
        case .reserved:
            // Reading the visit moves the gate on to S09 in place of this screen.
            await watcher.refetch()
        case .elsewhere(.visit(let id)):
            model.enterVisit(id)
        case .elsewhere(.emergency(let id)):
            model.showEmergency(visitId: id, redFlag: false)
        case .failed:
            if let error = centres.reserveError { model.sessionEnded(by: error) }
        }
    }

    #if DEBUG
    private func demoHooks() async {
        switch DemoVisit.view {
        case "list": chosenView = .list
        case "map": chosenView = .map
        default: break
        }
        guard DemoVisit.locates || DemoVisit.reserves || DemoVisit.selection != nil else { return }
        while centres.list == nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        // The same pick a pin or a row makes, without the haptic of a tap nobody made.
        if let wanted = DemoVisit.selection, DemoVisit.once("select") { centres.pick(wanted) }
        if DemoVisit.locates, DemoVisit.once("locate") { await centres.locate() }
        if DemoVisit.reserves, DemoVisit.once("reserve"), let list = centres.list,
           let centre = TicketRules.selected(picked: centres.picked, list: list) {
            await checkIn(centre.id)
        }
    }
    #endif
}

/// A count, or a dash when the clinic does not know it. A real zero prints 0.
struct Count: View {
    let value: Int?

    var body: some View {
        if let value {
            Text(verbatim: Bidi.ltr(String(value)))
                .accessibilityLabel(Text(verbatim: String(value)))
        } else {
            Dash()
        }
    }
}

/// One centre in the list: name, people ahead, distance, the wait as the figure that matters,
/// and a check mark on the chosen one.
private struct CentreRow: View {
    let centre: CentreOption
    let chosen: Bool
    let showsRule: Bool
    let action: () -> Void

    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                if showsRule {
                    DS.Color.rule
                        .frame(height: DS.Stroke.edge)
                        .padding(.horizontal, DS.Space.l)
                }
                HStack(spacing: DS.Space.m) {
                    VStack(alignment: .leading, spacing: DS.Space.xs) {
                        Text(verbatim: centreName(centre, lang: lang))
                            .dsText(.bodyStrong)
                            .foregroundStyle(DS.Color.ink)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        detail
                        if typeSize.isAccessibilitySize { wait }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if !typeSize.isAccessibilitySize { wait }
                    Image(systemName: "checkmark")
                        .dsText(.button)
                        .foregroundStyle(DS.Color.ink)
                        .opacity(chosen ? 1 : 0)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.vertical, DS.Space.m)
                .frame(minHeight: DS.Size.rowTwoLine)
                // The web's `bg-ground`: `raised` would hide the neutral pill on this row.
                .background(chosen ? DS.Color.ground : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(ListRowButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(chosen ? .isSelected : [])
        .accessibilityIdentifier("centre-row")
    }

    /// Your centre, people ahead, distance: on one line, wrapping when they do not fit.
    private var detail: some View {
        ChipFlow(spacing: DS.Space.m) {
            if centre.registered {
                Pill(lang.t("centre.yourCentre"), tone: .neutral)
            }
            // One text, so the label and its figure are read and judged together.
            if let ahead = centre.peopleAhead {
                Text(verbatim: "\(lang.t("centre.peopleAhead")) \(Bidi.ltr(String(ahead)))")
                    .fixedSize()
            } else {
                HStack(spacing: DS.Space.xs) {
                    Text(verbatim: lang.t("centre.peopleAhead"))
                    Dash()
                }
                .fixedSize()
            }
            if let distance = centre.distanceKm {
                Measure(value: distance, unit: lang.t("centre.unitKm"))
            }
        }
        .dsText(.secondary)
        .foregroundStyle(DS.Color.muted)
    }

    private var wait: some View {
        Measure(value: centre.waitMin, unit: lang.t("centre.unitMin"))
            .dsText(.statValue)
            .foregroundStyle(DS.Color.ink)
    }
}
