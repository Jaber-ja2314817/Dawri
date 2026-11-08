import DawriCore
import Foundation
import Observation

/// Whether updates arrive by stream, or by polling while the stream is down.
enum LiveMode: Sendable, Equatable {
    case live, polling
}

/// The port of frontend/src/state/useVisit.ts: holds one visit, refetches on every event, and
/// falls back to polling while the stream is down. A failed refresh keeps the last good visit.
@MainActor
@Observable
final class VisitWatcher {
    enum State {
        case loading
        case ready
        case failed
        case gone
    }

    private static let pollSeconds = 4
    private static let reopenSeconds = 15
    private static let backstopSeconds = 20

    private(set) var state: State
    private(set) var visit: Visit?
    private(set) var error: (any Error)?
    private(set) var live = LiveMode.polling
    private(set) var updatedAt: Date?

    @ObservationIgnored private let id: String
    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var asked = 0
    @ObservationIgnored private var answered = 0

    /// Starts from the last visit read, so a stage move shows no skeleton.
    init(id: String, model: AppModel) {
        self.id = id
        self.model = model
        let seed = model.seed(for: id)
        self.visit = seed
        self.state = seed == nil ? .loading : .ready
    }

    /// Runs until the surrounding task is cancelled or the visit is gone.
    func run() async {
        await withTaskGroup(of: Bool.self) { group in
            // Side by side, as the web opens the stream while the first read is out.
            group.addTask {
                await self.refetch()
                return false
            }
            group.addTask {
                await self.follow()
                return true
            }
            group.addTask {
                await self.backstop()
                return true
            }
            while let finished = await group.next() {
                if finished { group.cancelAll() }
            }
        }
    }

    func refetch() async {
        guard state != .gone else { return }
        asked += 1
        let ticket = asked
        do {
            let next = try await model.service.getVisit(visitId: id)
            guard ticket >= answered, state != .gone else { return }
            answered = ticket
            visit = next
            error = nil
            state = .ready
            updatedAt = Date()
            model.remember(next)
        } catch {
            guard ticket >= answered, state != .gone, !Task.isCancelled else { return }
            answered = ticket
            if model.sessionEnded(by: error) { return }
            if let clinic = error as? ClinicError, clinic.status == 404 {
                // What a demo reset leaves behind. Nothing here can come back.
                visit = nil
                state = .gone
                return
            }
            self.error = error
            if state != .ready { state = .failed }
        }
    }

    /// The stream while it lasts, then polling until it is time to open it again.
    private func follow() async {
        while !Task.isCancelled, state != .gone {
            for await update in await model.service.visitUpdates(visitId: id) {
                switch update {
                case .open:
                    live = .live
                    await refetch()
                case .changed:
                    await refetch()
                case .dropped:
                    live = .polling
                }
                if state == .gone { return }
            }
            live = .polling
            var waited = 0
            while waited < Self.reopenSeconds, !Task.isCancelled, state != .gone {
                try? await Task.sleep(for: .seconds(Self.pollSeconds))
                waited += Self.pollSeconds
                if !Task.isCancelled { await refetch() }
            }
        }
    }

    /// In case an event is ever missed.
    private func backstop() async {
        while !Task.isCancelled, state != .gone {
            try? await Task.sleep(for: .seconds(Self.backstopSeconds))
            if !Task.isCancelled { await refetch() }
        }
    }
}
