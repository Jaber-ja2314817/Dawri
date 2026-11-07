/// A reserved ticket has no number and no place: all three are nil until arrival.
public struct Ticket: Sendable, Codable, Equatable {
    public var id: String
    public var visitId: String
    public var number: String?
    public var state: TicketState
    public var centreId: String
    public var counterId: String
    public var counter: String
    public var counterAr: String
    public var peopleAhead: Int?
    public var estWaitMin: Int?
    public var expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case visitId = "visit_id"
        case number, state
        case centreId = "centre_id"
        case counterId = "counter_id"
        case counter
        case counterAr = "counter_ar"
        case peopleAhead = "people_ahead"
        case estWaitMin = "est_wait_min"
        case expiresAt = "expires_at"
    }
}

/// `refill_request` is `boolean | string | null` in types.ts. Null is a nil `RefillRequest?`.
public enum RefillRequest: Sendable, Codable, Equatable {
    case flag(Bool)
    case medicine(String)

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let flag = try? container.decode(Bool.self) {
            self = .flag(flag)
        } else {
            self = .medicine(try container.decode(String.self))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .flag(let value): try container.encode(value)
        case .medicine(let value): try container.encode(value)
        }
    }
}

public struct Intake: Sendable, Codable, Equatable {
    public var emergency: Bool
    public var language: String
    public var chiefComplaintPatientWords: String
    public var severity0To10: Int?
    public var selfMedication: [String]
    public var service: Service
    public var serviceConfidence: Double
    public var refillRequest: RefillRequest?
    public var questionsAsked: Int
    public var deniedRedFlags: [String]

    enum CodingKeys: String, CodingKey {
        case emergency, language
        case chiefComplaintPatientWords = "chief_complaint_patient_words"
        case severity0To10 = "severity_0_10"
        case selfMedication = "self_medication"
        case service
        case serviceConfidence = "service_confidence"
        case refillRequest = "refill_request"
        case questionsAsked = "questions_asked"
        case deniedRedFlags = "denied_red_flags"
    }
}

public enum ChatRole: String, Sendable, Codable, Equatable {
    case assistant
    case user
}

public struct ChatMessage: Sendable, Codable, Equatable {
    public var role: ChatRole
    public var content: String
    public var slot: String?
}

public struct MedicineLine: Sendable, Codable, Equatable {
    public var drug: String
    public var name: String
    public var line: String
}

/// `NearestEd extends Centre` in types.ts, flattened here.
public struct NearestEd: Sendable, Codable, Equatable, NamedCentre {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var lat: Double
    public var lng: Double
    public var distanceKm: Double

    enum CodingKeys: String, CodingKey {
        case id
        case nameEn = "name_en"
        case nameAr = "name_ar"
        case lat, lng
        case distanceKm = "distance_km"
    }
}

public struct EmergencyCard: Sendable, Codable, Equatable {
    public var reply: String
    /// The fixed text in each language, so the reply follows the language switch.
    public var replyEn: String?
    public var replyAr: String?
    public var selfHarm: Bool
    public var nearestEd: NearestEd

    enum CodingKeys: String, CodingKey {
        case reply
        case replyEn = "reply_en"
        case replyAr = "reply_ar"
        case selfHarm = "self_harm"
        case nearestEd = "nearest_ed"
    }
}

/// `Visit.chat` in types.ts.
public struct VisitChat: Sendable, Codable, Equatable {
    public var messages: [ChatMessage]
    public var language: String
}

/// `Visit.medicines` in types.ts.
public struct VisitMedicines: Sendable, Codable, Equatable {
    public var en: [MedicineLine]
    public var ar: [MedicineLine]
}

/// `Visit.go_to` and `ArriveResponse.go_to` in types.ts.
public struct GoTo: Sendable, Codable, Equatable {
    public var counter: String
    public var counterAr: String

    enum CodingKeys: String, CodingKey {
        case counter
        case counterAr = "counter_ar"
    }
}

/// `Visit.refill` and `ChatResponse.refill` in types.ts.
public struct RefillMedicine: Sendable, Codable, Equatable {
    public var medicine: String
}

public struct Visit: Sendable, Codable, Equatable {
    public var visitId: String
    public var patientId: String
    public var bookedBy: String?
    public var status: VisitStatus
    public var stage: VisitStage
    public var service: Service?
    public var createdAt: String
    public var arrivedAt: String?
    public var completedAt: String?
    public var centre: Centre?
    public var ticket: Ticket?
    public var intake: Intake?
    public var confirmedByPatient: Bool
    public var chat: VisitChat
    public var medicines: VisitMedicines
    public var emergency: EmergencyCard?
    public var goTo: GoTo?
    public var refill: RefillMedicine?
    public var rating: Int?

    enum CodingKeys: String, CodingKey {
        case visitId = "visit_id"
        case patientId = "patient_id"
        case bookedBy = "booked_by"
        case status, stage, service
        case createdAt = "created_at"
        case arrivedAt = "arrived_at"
        case completedAt = "completed_at"
        case centre, ticket, intake
        case confirmedByPatient = "confirmed_by_patient"
        case chat, medicines, emergency
        case goTo = "go_to"
        case refill, rating
    }
}

public struct VisitRow: Sendable, Codable, Equatable {
    public var visitId: String
    public var patientId: String
    public var status: VisitStatus
    public var stage: VisitStage
    public var service: Service?
    public var centreId: String?
    public var centre: Centre?
    public var createdAt: String
    public var completedAt: String?
    public var active: Bool

    enum CodingKeys: String, CodingKey {
        case visitId = "visit_id"
        case patientId = "patient_id"
        case status, stage, service
        case centreId = "centre_id"
        case centre
        case createdAt = "created_at"
        case completedAt = "completed_at"
        case active
    }
}
