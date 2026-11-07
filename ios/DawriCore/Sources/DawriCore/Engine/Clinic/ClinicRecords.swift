/// The rows SQLite holds. Named Record because `Ticket`, `Centre` and `VisitRow` are the API's.
/// Seed rows decode from engine.clinic.seed.json, so those keep the seed's column names.

public struct CentreRecord: Sendable, Codable, Equatable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var `operator`: String
    public var lat: Double
    public var lng: Double
    public var services: [String]
    public var hasEmergency: Int
    public var priorityAgeMin: Int

    enum CodingKeys: String, CodingKey {
        case id
        case nameEn = "name_en"
        case nameAr = "name_ar"
        case `operator`
        case lat, lng, services
        case hasEmergency = "has_emergency"
        case priorityAgeMin = "priority_age_min"
    }
}

public enum CounterStage: String, Sendable, Codable, Equatable {
    case triage
    case doctor
    case pharmacy

    /// `_VISIT_STATUS_BY_STAGE`.
    var visitStatus: VisitStatus {
        switch self {
        case .triage: .inTriage
        case .doctor: .inDoctor
        case .pharmacy: .inPharmacy
        }
    }
}

public struct CounterRecord: Sendable, Codable, Equatable {
    public var id: String
    public var centreId: String
    public var stage: CounterStage
    public var label: String
    public var labelAr: String
    public var staffId: String?
    public var prefix: String
    public var avgServiceSec: Int

    enum CodingKeys: String, CodingKey {
        case id
        case centreId = "centre_id"
        case stage, label
        case labelAr = "label_ar"
        case staffId = "staff_id"
        case prefix
        case avgServiceSec = "avg_service_sec"
    }
}

public struct StaffRecord: Sendable, Codable, Equatable {
    public var id: String
    public var centreId: String
    public var name: String
    public var role: String
    public var clinic: String?
    public var languages: [String]
    public var gender: String

    enum CodingKeys: String, CodingKey {
        case id
        case centreId = "centre_id"
        case name, role, clinic, languages, gender
    }
}

public struct PatientRecord: Sendable, Codable, Equatable {
    public var id: String
    public var qidDemo: String
    public var fullNameEn: String
    public var fullNameAr: String
    public var dob: String
    public var sex: String
    public var preferredLang: String
    public var registeredCentreId: String
    public var allergies: [String]
    public var chronic: [String]
    public var activeMeds: [String]

    enum CodingKeys: String, CodingKey {
        case id
        case qidDemo = "qid_demo"
        case fullNameEn = "full_name_en"
        case fullNameAr = "full_name_ar"
        case dob, sex
        case preferredLang = "preferred_lang"
        case registeredCentreId = "registered_centre_id"
        case allergies, chronic
        case activeMeds = "active_meds"
    }
}

public struct DependentLink: Sendable, Codable, Equatable {
    public var guardianId: String
    public var dependentId: String

    enum CodingKeys: String, CodingKey {
        case guardianId = "guardian_id"
        case dependentId = "dependent_id"
    }
}

public struct DrugRecord: Sendable, Codable, Equatable {
    public var id: String
    public var nameEn: String
    public var nameAr: String
    public var form: String
    public var defaultDose: String
    public var defaultFrequency: String
    public var defaultDays: Int
    public var allergyTags: [String]
    public var demoDefault: Int

    enum CodingKeys: String, CodingKey {
        case id
        case nameEn = "name_en"
        case nameAr = "name_ar"
        case form
        case defaultDose = "default_dose"
        case defaultFrequency = "default_frequency"
        case defaultDays = "default_days"
        case allergyTags = "allergy_tags"
        case demoDefault = "demo_default"
    }
}

public struct VisitRecord: Sendable, Codable, Equatable {
    public var id: String
    public var patientId: String
    public var centreId: String?
    public var status: VisitStatus
    public var service: Service?
    public var createdAt: String
    public var arrivedAt: String?
    public var completedAt: String?
    public var bookedBy: String?

    public init(
        id: String, patientId: String, centreId: String? = nil, status: VisitStatus = .intake,
        service: Service? = nil, createdAt: String, arrivedAt: String? = nil,
        completedAt: String? = nil, bookedBy: String? = nil
    ) {
        self.id = id
        self.patientId = patientId
        self.centreId = centreId
        self.status = status
        self.service = service
        self.createdAt = createdAt
        self.arrivedAt = arrivedAt
        self.completedAt = completedAt
        self.bookedBy = bookedBy
    }
}

/// `day` is the column the backend's `Ticket` dataclass leaves out.
public struct TicketRecord: Sendable, Codable, Equatable {
    public var id: String
    public var visitId: String?
    public var centreId: String
    public var counterId: String
    public var number: String?
    public var day: String?
    public var seq: Int?
    public var priority: Int = 0
    public var state: TicketState
    public var simulated: Bool = false
    public var callCount: Int = 0
    public var reservedAt: String?
    public var activatedAt: String?
    public var calledAt: String?
    public var doneAt: String?
    public var releasedAt: String?
}

public struct NumberSequenceRecord: Sendable, Codable, Equatable {
    public var centreId: String
    public var prefix: String
    public var day: String
    public var lastValue: Int
}

public struct PrescriptionRecord: Sendable, Codable, Equatable {
    public var visitId: String
    public var drug: String
    public var dose: String?
    public var frequency: String?
    public var days: Int?
    public var notes: String?
}

public struct EventRecord: Sendable, Codable, Equatable {
    public var visitId: String?
    public var type: String
    public var payload: JSONValue
    public var at: String

    public init(visitId: String?, type: String, payload: JSONValue, at: String) {
        self.visitId = visitId
        self.type = type
        self.payload = payload
        self.at = at
    }
}
