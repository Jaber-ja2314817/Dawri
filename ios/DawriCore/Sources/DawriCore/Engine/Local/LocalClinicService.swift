import Foundation
import os

/// On this phone mode: the whole clinic in one actor, with no network, no server and no model.
/// The receptionist is the scripted one and `QueueEngine` is the backend's queue, ported, so
/// the three demo patients behave as they do on the web. Screens only see `ClinicService`.
///
/// Nothing runs in the background except a wake task while a stream is open. Time is read when
/// someone calls: each call first runs `catchUp`, so a reservation that lapsed or a demo step
/// that fell due while the app was closed lands before the call reads anything.
///
/// Every route ends in `settle`, which tells open streams and saves the state.
public actor LocalClinicService: ClinicService {
    private static let log = Logger(subsystem: "com.jaber.dawri", category: "clinic")
    /// The queue moves one ticket a tick around its target, so a few ticks restore any gap.
    private static let maxCatchUpTicks: Int64 = 8

    let clock: @Sendable () -> Date
    let newId: @Sendable (String) -> String
    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let store: any ClinicStore
    let demoClinicEnabled: Bool
    /// Whether the store held a signed-in patient when this service was made. It needs no hop to
    /// the actor, so a saved session can open on Home with no Welcome frame.
    public nonisolated let restoredSession: Bool

    var engine: QueueEngine
    var state: LocalState
    private var saved: LocalState
    /// Messages from the pinned engines of demo steps, waiting for `settle`.
    var pending: [QueueMessage] = []
    private var listeners: [String: [UUID: AsyncStream<VisitUpdate>.Continuation]] = [:]
    private var wakeTask: Task<Void, Never>?
    private var wakeGeneration = 0

    /// - Parameters:
    ///   - sleep: waits this many seconds. Injected so a test can move its own clock instead.
    ///   - demoClinic: false leaves every ticket standing until something else moves it. The
    ///     app never turns it off. The golden replays do, because they move tickets as staff.
    public init(
        clock: @escaping @Sendable () -> Date = { Date() },
        newId: @escaping @Sendable (String) -> String = QueueEngine.randomId,
        store: any ClinicStore = FileClinicStore(),
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        },
        demoClinic: Bool = true
    ) {
        var engine = QueueEngine(clock: clock, newId: newId)
        let loaded = store.load()
        let state: LocalState
        if let loaded {
            state = loaded
        } else {
            do {
                state = try LocalState.fresh(engine: &engine)
            } catch {
                preconditionFailure("The bundled seed cannot be issued: \(error)")
            }
            Self.write(state, to: store)
        }
        self.clock = clock
        self.newId = newId
        self.sleep = sleep
        self.store = store
        self.demoClinicEnabled = demoClinic
        self.restoredSession = loaded?.subject != nil
        self.engine = engine
        self.state = state
        self.saved = state
    }

    deinit {
        wakeTask?.cancel()
        for group in listeners.values {
            for listener in group.values {
                listener.yield(.dropped)
                listener.finish()
            }
        }
    }

    /// The app keeps working from memory when a save fails, so a full disk cannot strand a
    /// patient mid-visit. The next save tries again with everything.
    private static func write(_ state: LocalState, to store: any ClinicStore) {
        do {
            try store.save(state)
        } catch {
            log.error("Saving the clinic failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // Catching up

    /// Everything that fell due since the last call, oldest kind of work first. It runs at the
    /// head of every route, as `expire_due` and the background loops would have by now.
    func catchUp() {
        let now = clock()
        do {
            try engine.expireDue(&state.clinic)
            try tickSimulatedLoad(now)
            runDueDemoSteps(until: ClinicTime.microseconds(of: now))
            try rollOverDay(now)
        } catch {
            Self.log.error("Catching up failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The loop in backend/main.py, by elapsed time. A tick starts nothing, so it can run late.
    private func tickSimulatedLoad(_ now: Date) throws {
        let interval = Int64(ClinicData.bundled.constants.simulateIntervalSec) * 1_000_000
        let due = (ClinicTime.microseconds(of: now) - state.lastTickMicros) / interval
        guard due > 0 else { return }
        for _ in 0..<min(due, Self.maxCatchUpTicks) {
            try SimulatedLoad.tick(&engine, &state.clinic)
        }
        state.lastTickMicros += due * interval
    }

    /// A deliberate difference from `bootstrap._stale`, which wipes everything: the phone keeps
    /// the patient's history for S12. So on a new Doha day the queue starts again and visits,
    /// chats, finished real tickets and events stay. While a real ticket is live, the day waits.
    /// `emergency_today` needs nothing here, because it reads the day from the event stamps.
    private func rollOverDay(_ now: Date) throws {
        let today = ClinicTime.dohaDay(now)
        guard today != state.queueDay,
              !state.clinic.tickets.contains(where: { $0.state.isLive && !$0.simulated })
        else { return }
        state.clinic.tickets.removeAll(where: \.simulated)
        state.clinic.sequences.removeAll()
        try SimulatedLoad.seedQueueState(&engine, &state.clinic, simulateLoad: true)
        state.queueDay = today
        state.lastTickMicros = ClinicTime.microseconds(of: now)
    }

    // After a route

    /// Tells open streams what moved, saves if anything did, and sets the next wake.
    func settle() {
        let messages = pending + engine.takeMessages()
        pending = []
        var told: Set<String> = []
        for message in messages {
            guard let visitId = message.visitId else { continue }
            told.insert(visitId)
            notify(visitId)
        }
        for visitId in listeners.keys where !told.contains(visitId) && changedSinceSave(visitId) {
            notify(visitId)
        }
        if state != saved {
            Self.write(state, to: store)
            saved = state
        }
        armWake()
    }

    private func changedSinceSave(_ visitId: String) -> Bool {
        state.chats[visitId] != saved.chats[visitId]
            || state.clinic.visit(visitId) != saved.clinic.visit(visitId)
    }

    func notify(_ visitId: String) {
        for listener in (listeners[visitId] ?? [:]).values {
            listener.yield(.changed)
        }
    }

    func notifyAll() {
        for visitId in listeners.keys { notify(visitId) }
    }

    // Live updates

    public func visitUpdates(visitId: String) -> AsyncStream<VisitUpdate> {
        catchUp()
        defer { settle() }
        let (stream, continuation) = AsyncStream.makeStream(of: VisitUpdate.self)
        // The web's stream route refuses here, which reaches a screen as an error.
        guard (try? patientVisit(visitId)) != nil else {
            continuation.yield(.dropped)
            continuation.finish()
            return stream
        }
        let token = UUID()
        continuation.yield(.open)
        listeners[visitId, default: [:]][token] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeListener(visitId: visitId, token: token) }
        }
        return stream
    }

    private func removeListener(visitId: String, token: UUID) {
        listeners[visitId]?[token] = nil
        if listeners[visitId]?.isEmpty == true { listeners[visitId] = nil }
        armWake()
    }

    /// Ends the streams on one visit, or on all of them, the way a lost connection would.
    func dropStreams(visitId: String? = nil) {
        let ids = visitId.map { [$0] } ?? Array(listeners.keys)
        for id in ids {
            for listener in (listeners[id] ?? [:]).values {
                listener.yield(.dropped)
                listener.finish()
            }
            listeners[id] = nil
        }
        armWake()
    }

    /// The next moment something changes without a call: a reservation running out or a demo
    /// step falling due.
    private func nextDueMicros() -> Int64? {
        let deadlines = state.clinic.tickets.compactMap { ticket -> Int64? in
            guard ticket.state == .reserved, let reservedAt = ticket.reservedAt else { return nil }
            return ClinicTime.storedMicroseconds(reservedAt) + QueueEngine.reservationWindow
        }
        return (deadlines + state.demoRuns.values.compactMap(\.pending?.dueMicros)).min()
    }

    /// While a stream is open, one task sleeps to the next due moment, so expiry and demo steps
    /// reach an open screen. Replaced after every route, as a route can change that moment.
    private func armWake() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeGeneration += 1
        guard !listeners.isEmpty, let due = nextDueMicros() else { return }
        let delay = max(0, Double(due - ClinicTime.microseconds(of: clock())) / 1_000_000)
        let (generation, sleep) = (wakeGeneration, sleep)
        wakeTask = Task { [weak self] in
            do {
                try await sleep(delay)
            } catch {
                return
            }
            await self?.wake(generation)
        }
    }

    private func wake(_ generation: Int) {
        guard generation == wakeGeneration else { return }
        catchUp()
        settle()
    }
}
