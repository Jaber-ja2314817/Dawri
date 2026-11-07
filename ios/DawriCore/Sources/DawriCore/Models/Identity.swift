/// Anything with a person's name in both languages. See `nameOf`.
public protocol NamedPerson {
    var fullNameEn: String { get }
    var fullNameAr: String { get }
}

/// Anything with a centre's name in both languages. See `centreName`.
public protocol NamedCentre {
    var nameEn: String { get }
    var nameAr: String { get }
}

public struct Centre: Sendable, Codable, Equatable, NamedCentre {
    public var id: String
    public var nameEn: String
    public var nameAr: String

    enum CodingKeys: String, CodingKey {
        case id
        case nameEn = "name_en"
        case nameAr = "name_ar"
    }
}

public struct DemoPatient: Sendable, Codable, Equatable, NamedPerson {
    public var id: String
    public var qidDemo: String
    public var fullNameEn: String
    public var fullNameAr: String

    enum CodingKeys: String, CodingKey {
        case id
        case qidDemo = "qid_demo"
        case fullNameEn = "full_name_en"
        case fullNameAr = "full_name_ar"
    }
}

/// `Patient extends DemoPatient` in types.ts, flattened here.
public struct Patient: Sendable, Codable, Equatable, NamedPerson {
    public var id: String
    public var qidDemo: String
    public var fullNameEn: String
    public var fullNameAr: String
    public var dob: String
    public var age: Int
    public var sex: String
    public var preferredLang: String
    public var allergies: [String]
    public var chronic: [String]
    public var activeMeds: [String]
    public var registeredCentre: Centre
    public var demo: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case qidDemo = "qid_demo"
        case fullNameEn = "full_name_en"
        case fullNameAr = "full_name_ar"
        case dob, age, sex
        case preferredLang = "preferred_lang"
        case allergies, chronic
        case activeMeds = "active_meds"
        case registeredCentre = "registered_centre"
        case demo
    }
}

public struct AuthStartResponse: Sendable, Codable, Equatable {
    public var otpSent: Bool

    enum CodingKeys: String, CodingKey {
        case otpSent = "otp_sent"
    }
}

/// The wire shape. `ClinicService.authVerify` keeps the token and hands back only the patient.
public struct AuthVerifyResponse: Sendable, Codable, Equatable {
    public var token: String
    public var patient: Patient
}

public struct Me: Sendable, Codable, Equatable {
    public var patient: Patient
    public var dependents: [Patient]
    /// `unknown` in types.ts: a FHIR-like bundle that no screen reads field by field.
    public var record: JSONValue
}

/// Any other string decodes to `.other`, never a failure, so the guard in Clinic server mode
/// gets to refuse it with a plain message. Only `.simulated` is safe to use.
public enum AiMode: Sendable, Codable, Equatable {
    case real
    case simulated
    case other(String)

    public init(rawValue: String) {
        switch rawValue {
        case "real": self = .real
        case "simulated": self = .simulated
        default: self = .other(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .real: "real"
        case .simulated: "simulated"
        case .other(let value): value
        }
    }

    public init(from decoder: any Decoder) throws {
        self.init(rawValue: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct Health: Sendable, Codable, Equatable {
    public var status: String
    public var aiMode: AiMode
    public var simulateLoad: Bool

    enum CodingKeys: String, CodingKey {
        case status
        case aiMode = "ai_mode"
        case simulateLoad = "simulate_load"
    }
}
