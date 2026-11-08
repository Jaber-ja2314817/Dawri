#if DEBUG
import DawriCore
import Foundation
import Synchronization

/// `-demoPatch`: reshapes an answer the real engine gave, for states it cannot reach by itself.
enum DemoPatch: String, Sendable, CaseIterable {
    /// `getVisit`: between stages, with no ticket on the visit.
    case noTicket
    /// `getVisit`: a completed visit with nothing prescribed.
    case noMedicines
    /// `getVisit`: a refill route with no medicine named.
    case noRefillMedicine
    /// `getVisit`: S06 with the self-harm reply, the engine's own text.
    case selfHarm
    /// `listCentres`: no centre offers the service.
    case noCentres
    /// `listCentres`: the service fell back to a GP first.
    case gpFirst
    /// `listCentres`: a suggested centre, worded as the engine words it.
    case suggestion
    /// `listCentres`: nothing chosen yet.
    case noDefaultCentre
    /// `getVisit` and `listCentres`: real zeros.
    case zeroAhead
    /// `getVisit` and `listCentres`: figures the clinic does not know.
    case unknownFigures
    /// `demoNextStep`: someone real stands ahead, so nothing moves, as the engine answers then.
    case demoWaiting
}

/// What the launch asked the proxy to do, and how many calls each route has had.
final class DemoFaults: Sendable {
    struct Failure: Sendable, Equatable {
        let code: String
        let detail: String?
    }

    private struct State {
        var failOnce: [String: Failure]
        var visitId: String?
        var calls: [String: Int] = [:]
    }

    private let failing: [String: Failure]
    private let holding: Set<String>
    private let patches: Set<DemoPatch>
    private let state: Mutex<State>

    init(fail: String?, failOnce: String?, hold: String?, patch: String?) {
        failing = Self.failures(fail)
        holding = Set(Self.list(hold))
        patches = Set(Self.list(patch).compactMap(DemoPatch.init(rawValue:)))
        state = Mutex(State(failOnce: Self.failures(failOnce)))
    }

    private static func list(_ text: String?) -> [String] {
        (text ?? "").split(separator: ",").map(String.init)
    }

    /// `route=code[:detail],...`
    private static func failures(_ text: String?) -> [String: Failure] {
        var failures: [String: Failure] = [:]
        for item in list(text) {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let code = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            failures[parts[0]] = Failure(code: code[0], detail: code.count > 1 ? code[1] : nil)
        }
        return failures
    }

    /// The visit that `active_visit` and `emergency_today` point at, unless a detail names one.
    func setVisit(_ visitId: String) {
        state.withLock { $0.visitId = visitId }
    }

    func has(_ patch: DemoPatch) -> Bool {
        patches.contains(patch)
    }

    /// `route:count` pairs, sorted, for `debug-calls`.
    var callCounts: String {
        state.withLock { state in
            state.calls.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: " ")
        }
    }

    /// Runs at the head of every route: counts the call, then holds or fails it as asked.
    func gate(_ route: String) async throws {
        let (failure, visitId) = state.withLock { state in
            state.calls[route, default: 0] += 1
            return (state.failOnce.removeValue(forKey: route) ?? failing[route], state.visitId)
        }
        if holding.contains(route) {
            while true { try await Task.sleep(for: .seconds(3600)) }
        }
        if let failure { throw Self.error(failure, visitId: visitId) }
    }

    /// Whether this route's stream should end at once or stay silent.
    func streamFault(_ route: String) -> (dropped: Bool, held: Bool) {
        let dropped = state.withLock { state in
            state.calls[route, default: 0] += 1
            return (state.failOnce.removeValue(forKey: route) ?? failing[route]) != nil
        }
        return (dropped, holding.contains(route))
    }

    private static func error(_ failure: Failure, visitId: String?) -> any Error {
        let code = failure.code
        switch code {
        case "network":
            return ClinicError.network
        case "internal_error":
            return ClinicError(status: 500, code: code, message: code)
        case "timeout":
            // What a request ended by the 45 s limit throws, the web's AbortError.
            return CancellationError()
        case "unauthorized":
            return ClinicError(status: 401, code: code, message: code)
        case "visit_not_found":
            return ClinicError(status: 404, code: code, message: code)
        case "active_visit", "emergency_today":
            return ClinicError(
                status: 409, code: code, message: code,
                extra: ["visit_id": .string(failure.detail ?? visitId ?? "")])
        case "too_far":
            return ClinicError(
                status: 409, code: code, message: code,
                extra: ["distance_m": .number(failure.detail.flatMap(Double.init) ?? 0)])
        default:
            return ClinicError(status: 409, code: code, message: code)
        }
    }
}

/// Stands between the screens and the real engine, so a screen can be shown failing or waiting
/// with nothing in the screen or the engine knowing. With no hooks it only forwards.
///
/// `@unchecked` because a Sendable class cannot be subclassed otherwise. Every stored property
/// is a `let` of a Sendable type.
class DemoClinicProxy: ClinicService, @unchecked Sendable {
    fileprivate let base: any ClinicService
    fileprivate let faults: DemoFaults

    init(base: any ClinicService, faults: DemoFaults) {
        self.base = base
        self.faults = faults
    }

    func authStart(qid: String) async throws -> AuthStartResponse {
        try await faults.gate("authStart")
        return try await base.authStart(qid: qid)
    }

    func authVerify(qid: String, otp: String) async throws -> Patient {
        try await faults.gate("authVerify")
        return try await base.authVerify(qid: qid, otp: otp)
    }

    func demoPatients() async throws -> [DemoPatient] {
        try await faults.gate("demoPatients")
        return try await base.demoPatients()
    }

    func health() async throws -> Health {
        try await faults.gate("health")
        return try await base.health()
    }

    func getMe() async throws -> Me {
        try await faults.gate("getMe")
        return try await base.getMe()
    }

    func createVisit(patientId: String?) async throws -> CreateVisitResponse {
        try await faults.gate("createVisit")
        return try await base.createVisit(patientId: patientId)
    }

    func listVisits() async throws -> [VisitRow] {
        try await faults.gate("listVisits")
        return try await base.listVisits()
    }

    func getVisit(visitId: String) async throws -> Visit {
        try await faults.gate("getVisit")
        return patched(try await base.getVisit(visitId: visitId))
    }

    func sendChat(visitId: String, text: String) async throws -> ChatResponse {
        try await faults.gate("sendChat")
        return try await base.sendChat(visitId: visitId, text: text)
    }

    func confirmIntake(visitId: String, service: Service?) async throws -> ConfirmResponse {
        try await faults.gate("confirmIntake")
        return try await base.confirmIntake(visitId: visitId, service: service)
    }

    func continueRefill(visitId: String) async throws -> ConfirmResponse {
        try await faults.gate("continueRefill")
        return try await base.continueRefill(visitId: visitId)
    }

    func emergencyOverride(visitId: String) async throws -> OverrideResponse {
        try await faults.gate("emergencyOverride")
        return try await base.emergencyOverride(visitId: visitId)
    }

    func listCentres(
        service: String, visitId: String, lat: Double?, lng: Double?
    ) async throws -> CentreList {
        try await faults.gate("listCentres")
        return patched(try await base.listCentres(service: service, visitId: visitId, lat: lat, lng: lng))
    }

    func reserve(visitId: String, centreId: String) async throws -> ReserveResponse {
        try await faults.gate("reserve")
        return try await base.reserve(visitId: visitId, centreId: centreId)
    }

    func arrive(visitId: String, body: ArriveBody) async throws -> ArriveResponse {
        try await faults.gate("arrive")
        return try await base.arrive(visitId: visitId, body: body)
    }

    func rateVisit(visitId: String, stars: Int) async throws -> RatingResponse {
        try await faults.gate("rateVisit")
        return try await base.rateVisit(visitId: visitId, stars: stars)
    }

    var isSignedIn: Bool {
        get async { await base.isSignedIn }
    }

    func signOut() async {
        await base.signOut()
    }

    /// `-demoFail visitUpdates=...` drops the stream, which is the polling state. `-demoHold
    /// visitUpdates` opens one that never speaks.
    func visitUpdates(visitId: String) async -> AsyncStream<VisitUpdate> {
        let (dropped, held) = faults.streamFault("visitUpdates")
        if held { return AsyncStream { _ in } }
        guard dropped else { return await base.visitUpdates(visitId: visitId) }
        return AsyncStream { continuation in
            continuation.yield(.dropped)
            continuation.finish()
        }
    }

    private func patched(_ answer: Visit) -> Visit {
        var visit = answer
        if faults.has(.noTicket) {
            visit.ticket = nil
            visit.goTo = nil
        }
        if faults.has(.noMedicines) {
            visit.medicines.en = []
            visit.medicines.ar = []
        }
        if faults.has(.noRefillMedicine) {
            visit.refill = nil
        }
        if faults.has(.selfHarm), var card = visit.emergency {
            card.selfHarm = true
            card.reply = Scripted.emergencyReply(lang: visit.chat.language, selfHarm: true)
            card.replyEn = Scripted.emergencyReply(lang: "en", selfHarm: true)
            card.replyAr = Scripted.emergencyReply(lang: "ar", selfHarm: true)
            visit.emergency = card
        }
        if faults.has(.zeroAhead), visit.ticket != nil {
            visit.ticket?.peopleAhead = 0
            visit.ticket?.estWaitMin = 0
        }
        if faults.has(.unknownFigures), visit.ticket != nil {
            visit.ticket?.peopleAhead = nil
            visit.ticket?.estWaitMin = nil
        }
        return visit
    }

    private func patched(_ answer: CentreList) -> CentreList {
        var list = answer
        if faults.has(.noCentres) {
            list.centres = []
            list.defaultCentreId = nil
            list.suggestion = nil
        }
        if faults.has(.gpFirst) {
            list.serviceFallback = true
            list.effectiveService = Service.gp.rawValue
        }
        if faults.has(.suggestion), let best = list.centres.first(where: { !$0.registered }) {
            list.suggestion = LocalClinicService.demoSuggestion(for: best)
        }
        if faults.has(.noDefaultCentre) {
            list.defaultCentreId = nil
        }
        if faults.has(.zeroAhead) {
            for index in list.centres.indices {
                list.centres[index].peopleAhead = 0
                list.centres[index].waitMin = 0
            }
        }
        if faults.has(.unknownFigures) {
            for index in list.centres.indices {
                list.centres[index].peopleAhead = nil
                list.centres[index].waitMin = nil
                list.centres[index].distanceKm = nil
            }
        }
        return list
    }
}

/// The proxy on this phone: the Demo control and Reset stay, because they look for `DemoDriving`.
final class DemoDrivenClinicProxy: DemoClinicProxy, DemoDriving, @unchecked Sendable {
    private let driver: any DemoDriving

    init(base: any ClinicService, driver: any DemoDriving, faults: DemoFaults) {
        self.driver = driver
        super.init(base: base, faults: faults)
    }

    @discardableResult
    func demoNextStep(visitId: String) async throws -> DemoStepOutcome {
        if faults.has(.demoWaiting) { return .waiting }
        return try await driver.demoNextStep(visitId: visitId)
    }

    func demoPlan(visitId: String) async throws -> [DemoPlannedStep] {
        try await driver.demoPlan(visitId: visitId)
    }

    func resetDemo() async throws {
        try await driver.resetDemo()
    }
}
#endif
