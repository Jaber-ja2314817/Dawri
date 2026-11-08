import DawriCore
import Observation
import SwiftUI

/// S09. How long do I have to arrive? The port of frontend/src/pages/patient/Reserved.tsx.
///
/// A reserved ticket has **no number and no place**, so nothing here shows a ticket number,
/// people ahead or the hue. When the check-in runs out, the same route steps in place to the
/// expired state, so there is no way back into the countdown.
struct ReservedScreen: View {
    let visit: Visit
    let watcher: VisitWatcher

    @Environment(AppModel.self) private var model

    var body: some View {
        ReservedContent(visit: visit, watcher: watcher, model: model)
    }
}

/// The arrival half of Reserved.tsx: which button is busy, and what a refusal leaves on screen.
@MainActor
@Observable
final class ArrivalModel {
    enum Busy: Equatable {
        case button, location, code
    }

    enum Outcome: Equatable {
        /// The ticket is active. The visit is read again, which moves the gate on to S10.
        case arrived
        /// `ticket_expired`: read the visit again, which shows the expired step.
        case refetch
        case emergency(visitId: String)
        /// Something is now on screen: a notice, an error block or the door code error.
        case shown
    }

    enum Note: Equatable {
        case tooFar(metres: Int)
        case locationFailed
    }

    private(set) var busy: Busy?
    private(set) var note: Note?
    private(set) var failure: (any Error)?
    /// `error.wrong_door`, under the door code field.
    private(set) var wrongDoor = false
    /// Bumped when the clinic says the patient is too far, which they should feel. Arrival's own
    /// haptic plays on S10, on the frame the number appears.
    private(set) var failedTicks = 0

    @ObservationIgnored private let service: any ClinicService
    @ObservationIgnored private let location: any LocationSource
    @ObservationIgnored private let visitId: String

    init(service: any ClinicService, location: any LocationSource, visitId: String) {
        self.service = service
        self.location = location
        self.visitId = visitId
    }

    /// `hereByButton`.
    func here() async -> Outcome {
        start(.button)
        return await send(.button)
    }

    /// `hereByLocation`: one reading, then the clinic checks the distance.
    func hereByLocation() async -> Outcome {
        start(.location)
        let point: LocationPoint
        do {
            point = try await location.currentPoint()
        } catch {
            note = .locationFailed
            busy = nil
            return .shown
        }
        return await send(.location(lat: point.lat, lng: point.lng))
    }

    /// The door code, as the clinic reads it.
    func code(_ typed: String) async -> Outcome {
        start(.code)
        return await send(.qrCode(TicketRules.doorCode(typed)))
    }

    func clearDoorError() {
        wrongDoor = false
    }

    private func start(_ acting: Busy) {
        note = nil
        failure = nil
        wrongDoor = false
        busy = acting
    }

    private func send(_ body: ArriveBody) async -> Outcome {
        do {
            _ = try await service.arrive(visitId: visitId, body: body)
            return .arrived
        } catch {
            busy = nil
            switch TicketRules.arrivalFailure(error) {
            case .refetch:
                return .refetch
            case .emergency(let id):
                return .emergency(visitId: id)
            case .tooFar(let metres):
                note = .tooFar(metres: metres)
                failedTicks += 1
            case .wrongDoor:
                // The sheet is in front, so it gives this haptic itself.
                wrongDoor = true
            case .failed:
                failure = error
            }
            return .shown
        }
    }

    /// After a move, so a spinner never outlives the screen's reason for it.
    func settle() {
        busy = nil
    }
}

private struct ReservedContent: View {
    let visit: Visit
    let watcher: VisitWatcher
    let model: AppModel

    @Environment(\.lang) private var lang
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrival: ArrivalModel
    @State private var ranOut = false
    @State private var showsDoorSheet = false
    @State private var doorCode = ""

    init(visit: Visit, watcher: VisitWatcher, model: AppModel) {
        self.visit = visit
        self.watcher = watcher
        self.model = model
        var location = model.features.location
        #if DEBUG
        location = DemoVisit.location(location, service: model.service, visitId: visit.visitId)
        #endif
        _arrival = State(
            initialValue: ArrivalModel(
                service: model.service, location: location, visitId: visit.visitId))
    }

    private var expired: Bool { visit.stage == .expired }

    private var title: String {
        expired
            ? lang.t("reserved.expiredTitle")
            : visit.centre.map { centreName($0, lang: lang) } ?? lang.t("screen.reserved")
    }

    var body: some View {
        PatientScaffold {
            ZStack(alignment: .topLeading) {
                if expired {
                    expiredStep
                        .transition(step)
                } else {
                    waitingStep
                        .transition(step)
                }
            }
            .animation(DS.Motion.resolved(DS.Motion.push, reduceMotion: reduceMotion), value: expired)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("screen-reserved")
        }
        .navigationTitle(title)
        .sensoryFeedback(DS.Haptic.failed, trigger: arrival.failedTicks)
        .sheet(isPresented: $showsDoorSheet) {
            DoorCodeSheet(
                code: $doorCode, isBusy: arrival.busy == .code, wrongDoor: arrival.wrongDoor,
                onEdit: { arrival.clearDoorError() },
                onSubmit: { Task { await submitCode() } },
                onCancel: { showsDoorSheet = false })
        }
        // `GET` runs the expiry. The retry covers a phone clock slightly ahead of the clinic's.
        .task(id: ranOut && !expired) {
            guard ranOut, !expired else { return }
            while !Task.isCancelled {
                await watcher.refetch()
                try? await Task.sleep(for: TicketRules.expiryRetry)
            }
        }
        #if DEBUG
        .task { await demoHooks() }
        #endif
    }

    /// An in-place step that mirrors in Arabic, or a cross-fade with Reduce Motion.
    private var step: AnyTransition {
        reduceMotion ? .opacity : .push(from: .trailing)
    }

    // Waiting

    private var waitingStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ScreenTitle(title)
            Card {
                VStack(spacing: DS.Space.s) {
                    Text(verbatim: lang.t("reserved.valid"))
                        .dsText(.bodyStrong)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("reserved-valid")
                    CountdownText(expiresAt: visit.ticket?.expiresAt) { ranOut = $0 }
                    Text(verbatim: lang.t("reserved.activates"))
                        .dsText(.secondary)
                        .foregroundStyle(DS.Color.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.vertical, DS.Space.s)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("reserved-card")

            switch arrival.note {
            case .tooFar(let metres):
                Notice(Bidi.fill(
                    "reserved.tooFar", ["distance": metres, "limit": TicketRules.geofenceMetres],
                    lang: lang))
                    .accessibilityLabel(Text(verbatim: lang.t(
                        "reserved.tooFar", ["distance": metres, "limit": TicketRules.geofenceMetres])))
                    .accessibilityIdentifier("too-far")
            case .locationFailed:
                Notice(lang.t("reserved.locationFailed"))
                    .accessibilityIdentifier("location-failed")
            case nil:
                EmptyView()
            }
            if let failure = arrival.failure {
                ErrorBlock(message: errorText(failure, strings: .bundled, lang: lang))
                    .accessibilityIdentifier("arrive-error")
            }

            Button(lang.t("reserved.here")) {
                Task { await act(arrival.here()) }
            }
            .buttonStyle(PrimaryButtonStyle())
            .dsLoading(arrival.busy == .button)
            .disabled(arrival.busy != nil)
            .accessibilityIdentifier("im-here")

            Button(lang.t("reserved.useLocation")) {
                Task { await act(arrival.hereByLocation()) }
            }
            .buttonStyle(SecondaryButtonStyle())
            .dsLoading(arrival.busy == .location)
            .disabled(arrival.busy != nil)
            .accessibilityIdentifier("check-location")

            Button {
                showsDoorSheet = true
            } label: {
                Label {
                    Text(verbatim: lang.t("reserved.scan"))
                } icon: {
                    Image(systemName: "qrcode.viewfinder")
                }
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(arrival.busy != nil)
            .accessibilityIdentifier("reserved-scan")
        }
    }

    // Expired

    private var expiredStep: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            ScreenTitle(title)
                .accessibilityIdentifier("reserved-expired")
            Text(verbatim: lang.t("reserved.expiredBody"))
                .dsText(.body)
                .foregroundStyle(DS.Color.ink)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(lang.t("reserved.chooseAgain")) {
                chooseAgain()
            }
            .buttonStyle(PrimaryButtonStyle())
            .accessibilityIdentifier("choose-again")
        }
    }

    // Acting

    private func act(_ outcome: ArrivalModel.Outcome) async {
        switch outcome {
        case .arrived:
            showsDoorSheet = false
            await watcher.refetch()
            arrival.settle()
        case .refetch:
            showsDoorSheet = false
            await watcher.refetch()
        case .emergency(let id):
            showsDoorSheet = false
            model.showEmergency(visitId: id, redFlag: false)
        case .shown:
            // Only the door code's own error stays in the sheet. Anything else is on the screen.
            if !arrival.wrongDoor { showsDoorSheet = false }
            if let failure = arrival.failure { model.sessionEnded(by: failure) }
        }
    }

    private func submitCode() async {
        await act(arrival.code(doorCode))
    }

    /// S08 in place of this entry, so Back goes Home and never into the countdown.
    private func chooseAgain() {
        let id = visit.visitId
        Task { await model.replace(.visit(id: id, screen: .reserved), with: .visit(id: id, screen: .centre)) }
    }

    #if DEBUG
    private func demoHooks() async {
        if let code = DemoVisit.doorCode { doorCode = code }
        if DemoVisit.opensDoorSheet, DemoVisit.once("doorSheet") {
            showsDoorSheet = true
            try? await Task.sleep(for: .milliseconds(700))
        }
        guard let how = DemoVisit.arrival, DemoVisit.once("arrive") else { return }
        switch how {
        case "button": await act(arrival.here())
        case "location": await act(arrival.hereByLocation())
        case "code": await submitCode()
        default: break
        }
    }
    #endif
}
