import DawriCore
import Foundation
import Observation

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

    private(set) var state = State.loading
    private(set) var visit: Visit?
    private(set) var error: (any Error)?

    @ObservationIgnored private let id: String
    @ObservationIgnored private let service: any ClinicService
    @ObservationIgnored private var asked = 0
    @ObservationIgnored private var answered = 0

    init(id: String, service: any ClinicService) {
        self.id = id
        self.service = service
    }

    /// Runs until the surrounding task is cancelled or the visit is gone.
    func run() async {
        await refetch()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await self.follow() }
            group.addTask { await self.backstop() }
            await group.next()
            group.cancelAll()
        }
    }

    func refetch() async {
        guard state != .gone else { return }
        asked += 1
        let ticket = asked
        do {
            let next = try await service.getVisit(visitId: id)
            guard ticket >= answered, state != .gone else { return }
            answered = ticket
            visit = next
            error = nil
            state = .ready
        } catch {
            guard ticket >= answered, state != .gone else { return }
            answered = ticket
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
            for await update in await service.visitUpdates(visitId: id) {
                switch update {
                case .open, .changed: await refetch()
                case .dropped: break
                }
                if state == .gone { return }
            }
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
