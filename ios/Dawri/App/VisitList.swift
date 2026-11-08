import DawriCore
import Foundation
import Observation

/// The port of frontend/src/state/useVisitList.ts, for S03 and S12. A new load supersedes the
/// one before it, and a failed one keeps the rows it had.
@MainActor
@Observable
final class VisitList {
    enum State: Sendable, Equatable {
        case loading, ready, failed
    }

    private(set) var rows: [VisitRow] = []
    private(set) var state = State.loading
    private(set) var error: (any Error)?

    @ObservationIgnored private let model: AppModel
    @ObservationIgnored private var request = 0

    init(model: AppModel) {
        self.model = model
    }

    func load() async {
        request += 1
        let mine = request
        state = .loading
        do {
            let next = try await model.service.listVisits()
            guard mine == request else { return }
            rows = next
            state = .ready
        } catch {
            guard mine == request, !model.sessionEnded(by: error) else { return }
            self.error = error
            state = .failed
        }
    }

    func retry() async {
        await load()
    }
}
