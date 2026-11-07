/// Port of backend/simulate.py: sequence starts, simulated waiting tickets and the load tick.
public enum SimulatedLoad {
    private static var constants: ClinicData.Constants { ClinicData.bundled.constants }

    /// Starts today's sequences so the real numbers land the same with or without load.
    public static func seedQueueState(
        _ engine: inout QueueEngine, _ state: inout ClinicState, simulateLoad: Bool
    ) throws {
        let day = ClinicTime.dohaDay(engine.clock())
        let tickets = simulateLoad ? constants.simulatedTickets : []
        func simulated(centreId: String, prefix: String) -> Int {
            tickets.reduce(0) { total, row in
                let counter = state.counter(row.key)
                let matches = counter?.centreId == centreId && counter?.prefix == prefix
                return total + (matches ? row.value : 0)
            }
        }
        for centre in constants.nextRealNumber {
            for row in centre.value {
                let last = row.value - 1 - simulated(centreId: centre.key, prefix: row.key)
                if let found = state.sequences.firstIndex(where: {
                    $0.centreId == centre.key && $0.prefix == row.key && $0.day == day
                }) {
                    state.sequences[found].lastValue = last
                } else {
                    state.sequences.append(
                        NumberSequenceRecord(
                            centreId: centre.key, prefix: row.key, day: day, lastValue: last))
                }
            }
        }
        for row in tickets {
            for _ in 0..<row.value {
                _ = try engine.issueSimulated(&state, counterId: row.key)
            }
        }
    }

    /// `_tick_counters`: each ticked counter with its seed target and waiting simulated tickets.
    /// Protected centres are left alone: a tick there would consume numbers and break T-014.
    static func tickCounters(_ state: ClinicState) -> [(counterId: String, target: Int, waiting: Int)] {
        constants.simulatedTickets.compactMap { row in
            guard let counter = state.counter(row.key), counter.stage == .triage,
                  !constants.protectedCentres.contains(counter.centreId)
            else { return nil }
            let waiting = state.tickets.count {
                $0.counterId == row.key && $0.state == .active && $0.simulated
            }
            return (row.key, row.value, waiting)
        }
    }

    /// One tick: every other counter moves one ticket towards or away from its target, so it
    /// stays within one. It runs on the engine's clock and starts nothing, so the caller can
    /// run it as many times as ticks have passed.
    public static func tick(_ engine: inout QueueEngine, _ state: inout ClinicState) throws {
        for (counterId, target, waiting) in tickCounters(state) {
            if waiting >= target {
                _ = try engine.completeSimulated(&state, counterId: counterId)
            } else {
                _ = try engine.issueSimulated(&state, counterId: counterId)
            }
        }
    }
}
