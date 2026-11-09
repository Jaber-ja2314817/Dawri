public struct CreateVisitResponse: Sendable, Codable, Equatable {
    public var visitId: String
    public var status: VisitStatus
    public var language: String
    public var opening: String

    enum CodingKeys: String, CodingKey {
        case visitId = "visit_id"
        case status, language, opening
    }
}

public struct ChatResponse: Sendable, Codable, Equatable {
    public var reply: String
    public var done: Bool
    public var emergency: Bool
    public var intake: Intake?
    public var refill: RefillMedicine?
    public var denied: [String]
    public var aiSource: String
    public var selfHarm: Bool
    public var status: VisitStatus
    public var transcript: String?
    public var nearestEd: NearestEd?

    enum CodingKeys: String, CodingKey {
        case reply, done, emergency, intake, refill, denied
        case aiSource = "ai_source"
        case selfHarm = "self_harm"
        case status, transcript
        case nearestEd = "nearest_ed"
    }
}

/// Unused on purpose. The app never uploads speech: voice is transcribed on the phone.
/// The shape stays only so this file keeps one type for every name in types.ts.
public struct TranscribeResponse: Sendable, Codable, Equatable {
    public var text: String
}

public struct ConfirmResponse: Sendable, Codable, Equatable {
    public var status: VisitStatus
    public var service: Service
    public var intake: Intake?
}

public struct OverrideResponse: Sendable, Codable, Equatable {
    public var status: VisitStatus
    /// Always nil. The override logs and still gives no ticket.
    public var ticket: Ticket?
    public var message: String
    public var messageAr: String

    enum CodingKeys: String, CodingKey {
        case status, ticket, message
        case messageAr = "message_ar"
    }
}

/// `CentreOption extends Centre` in types.ts, flattened here.
public struct CentreOption: Sendable, Codable, Equatable, NamedCentre {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var `operator`: String
    public var lat: Double
    public var lng: Double
    public var waitMin: Int?
    public var peopleAhead: Int?
    public var distanceKm: Double?
    public var registered: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case nameEn = "name_en"
        case nameAr = "name_ar"
        case `operator`
        case lat, lng
        case waitMin = "wait_min"
        case peopleAhead = "people_ahead"
        case distanceKm = "distance_km"
        case registered
    }
}

/// `CentreList.suggestion` in types.ts.
public struct CentreSuggestion: Sendable, Codable, Equatable {
    public var centreId: String
    public var reasonEn: String
    public var reasonAr: String

    enum CodingKeys: String, CodingKey {
        case centreId = "centre_id"
        case reasonEn = "reason_en"
        case reasonAr = "reason_ar"
    }
}

public struct CentreList: Sendable, Codable, Equatable {
    public var service: String
    public var effectiveService: String
    public var serviceFallback: Bool
    public var defaultCentreId: String?
    public var centres: [CentreOption]
    public var suggestion: CentreSuggestion?

    enum CodingKeys: String, CodingKey {
        case service
        case effectiveService = "effective_service"
        case serviceFallback = "service_fallback"
        case defaultCentreId = "default_centre_id"
        case centres, suggestion
    }
}

public struct ReserveResponse: Sendable, Codable, Equatable {
    public var ticket: Ticket
    public var expiresAt: String
    public var checkInValidMin: Int
    public var message: String
    public var messageAr: String

    enum CodingKeys: String, CodingKey {
        case ticket
        case expiresAt = "expires_at"
        case checkInValidMin = "check_in_valid_min"
        case message
        case messageAr = "message_ar"
    }
}

/// Encodes as exactly one of `{button:true}`, `{lat,lng}`, `{qr_code}`.
public enum ArriveBody: Sendable, Codable, Equatable {
    case button
    case location(lat: Double, lng: Double)
    case qrCode(String)

    enum CodingKeys: String, CodingKey {
        case button, lat, lng
        case qrCode = "qr_code"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let forms = Set(container.allKeys.map(\.stringValue))
        switch forms {
        case ["button"] where try container.decode(Bool.self, forKey: .button):
            self = .button
        case ["lat", "lng"]:
            self = .location(
                lat: try container.decode(Double.self, forKey: .lat),
                lng: try container.decode(Double.self, forKey: .lng))
        case ["qr_code"]:
            self = .qrCode(try container.decode(String.self, forKey: .qrCode))
        default:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Expected exactly one of button, lat and lng, or qr_code."))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .button:
            try container.encode(true, forKey: .button)
        case .location(let lat, let lng):
            try container.encode(lat, forKey: .lat)
            try container.encode(lng, forKey: .lng)
        case .qrCode(let code):
            try container.encode(code, forKey: .qrCode)
        }
    }
}

public struct ArriveResponse: Sendable, Codable, Equatable {
    public var ticket: Ticket
    public var goTo: GoTo?

    enum CodingKeys: String, CodingKey {
        case ticket
        case goTo = "go_to"
    }
}

public struct RatingResponse: Sendable, Codable, Equatable {
    public var rating: Int
}
