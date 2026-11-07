public enum VisitStatus: String, Sendable, Codable, Equatable, CaseIterable {
    case intake
    case redirectedEmergency = "redirected_emergency"
    case deflectedRefill = "deflected_refill"
    case reserved
    case expired
    case inTriage = "in_triage"
    case inDoctor = "in_doctor"
    case inPharmacy = "in_pharmacy"
    case completed
    case cancelled

    /// `STAGES` in backend/routers/visits.py.
    public var stage: VisitStage {
        switch self {
        case .intake: .intake
        case .redirectedEmergency: .emergency
        case .deflectedRefill: .refill
        case .reserved: .reserved
        case .expired: .expired
        case .inTriage: .triage
        case .inDoctor: .doctor
        case .inPharmacy: .pharmacy
        case .completed: .completed
        case .cancelled: .cancelled
        }
    }
}

public enum VisitStage: String, Sendable, Codable, Equatable, Hashable, CaseIterable {
    case intake
    case emergency
    case refill
    case reserved
    case expired
    case triage
    case doctor
    case pharmacy
    case completed
    case cancelled
}

public enum Service: String, Sendable, Codable, Equatable, CaseIterable {
    case gp
    case dental
    case refill
    case vaccination
    case labOnly = "lab_only"
    case womensHealth = "womens_health"
    case mentalHealth = "mental_health"
    case other
}

public enum TicketState: String, Sendable, Codable, Equatable, CaseIterable {
    case reserved
    case active
    case called
    case serving
    case done
    case released
    case expired
}
