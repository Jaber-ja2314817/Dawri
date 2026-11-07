/// The queue's refusals, with the statuses of `_QUEUE_ERROR_STATUS` in backend/main.py.
extension ClinicError {
    static func ticketNotFound(_ message: String) -> ClinicError {
        ClinicError(status: 404, code: "ticket_not_found", message: message)
    }

    static func ticketExpired(_ message: String) -> ClinicError {
        ClinicError(status: 410, code: "ticket_expired", message: message)
    }

    static func invalidTransition(_ message: String) -> ClinicError {
        ClinicError(status: 409, code: "invalid_transition", message: message)
    }

    static func visitNotEligible(_ message: String) -> ClinicError {
        ClinicError(status: 409, code: "visit_not_eligible", message: message)
    }

    static func visitHasLiveTicket(_ message: String) -> ClinicError {
        ClinicError(status: 409, code: "visit_has_live_ticket", message: message)
    }

    static func counterBusy(_ message: String) -> ClinicError {
        ClinicError(status: 409, code: "counter_busy", message: message)
    }
}

/// `CallResult` in backend/adapters/queue_base.py.
public struct CallResult: Sendable, Equatable {
    public var called: TicketRecord?
    public var autoCompleted: [TicketRecord]
}

/// `Position` in backend/adapters/queue_base.py.
public struct TicketPosition: Sendable, Equatable {
    public var ticketId: String
    public var state: TicketState
    public var number: String?
    public var peopleAhead: Int?
    public var estWaitMin: Int?
    public var expiresAt: String?
}

/// What `counter_wait` and `centre_wait` return.
public struct QueueWait: Sendable, Equatable {
    public var peopleAhead: Int
    public var waitMin: Int
}

/// A row of `queue_snapshot`.
public struct QueueRow: Sendable, Equatable {
    public var ticketId: String
    public var number: String?
    public var state: TicketState
    public var priority: Int
    public var simulated: Bool
    public var visitId: String?
    public var activatedAt: String?
    public var calledAt: String?
    public var callCount: Int
    public var label: String?
    public var position: Int?
}

/// The channels of backend/events.py.
public enum QueueChannel: Sendable, Equatable {
    case counter(String)
    case visit(String)
    case display(String)

    public var name: String {
        switch self {
        case .counter(let id): "counter:\(id)"
        case .visit(let id): "visit:\(id)"
        case .display(let id): "display:\(id)"
        }
    }
}

/// One message the backend would have published, after its transaction committed.
public struct QueueMessage: Sendable, Equatable {
    public var channel: QueueChannel
    public var event: JSONValue

    /// The visit this message wakes, if it is on a visit channel.
    public var visitId: String? {
        if case .visit(let id) = channel { id } else { nil }
    }
}
