/// A chat that cannot become a valid intake. The message names the field and holds no patient text.
public struct IntakeParseError: Error, Sendable {
    public let message: String
}

/// What `validate_intake` is handed, before any of the schema's rules have run.
public struct IntakeDraft: Sendable {
    public var emergency = false
    public var language: String
    public var chiefComplaint: String
    public var chiefComplaintPatientWords: String
    public var duration: String?
    public var severity0To10: Int?
    public var associated: [String] = []
    public var selfMedication: [String] = []
    public var service: String
    public var serviceConfidence: Double
    public var summaryForNurse: String
    public var refillRequest: String?
    public var questionsAsked: Int
    public var deniedRedFlags: [String] = []
    public var patientConcerns: String?

    public init(
        emergency: Bool = false, language: String, chiefComplaint: String,
        chiefComplaintPatientWords: String, duration: String? = nil, severity0To10: Int? = nil,
        associated: [String] = [], selfMedication: [String] = [], service: String,
        serviceConfidence: Double, summaryForNurse: String, refillRequest: String? = nil,
        questionsAsked: Int, deniedRedFlags: [String] = [], patientConcerns: String? = nil
    ) {
        self.emergency = emergency
        self.language = language
        self.chiefComplaint = chiefComplaint
        self.chiefComplaintPatientWords = chiefComplaintPatientWords
        self.duration = duration
        self.severity0To10 = severity0To10
        self.associated = associated
        self.selfMedication = selfMedication
        self.service = service
        self.serviceConfidence = serviceConfidence
        self.summaryForNurse = summaryForNurse
        self.refillRequest = refillRequest
        self.questionsAsked = questionsAsked
        self.deniedRedFlags = deniedRedFlags
        self.patientConcerns = patientConcerns
    }
}

/// The full record the scripted receptionist produces: `Intake` in backend/ai/intake.py. Staff read
/// all of it. A patient sees only `patientView`, the type this app calls `Intake`.
public struct IntakeRecord: Sendable, Codable, Equatable {
    public var emergency: Bool
    public var language: String
    public var chiefComplaint: String
    public var chiefComplaintPatientWords: String
    public var duration: String?
    public var severity0To10: Int?
    public var associated: [String]
    public var selfMedication: [String]
    public var service: Service
    public var serviceConfidence: Double
    public var summaryForNurse: String
    public var refillRequest: String?
    public var questionsAsked: Int
    public var deniedRedFlags: [String]
    public var patientConcerns: String?

    enum CodingKeys: String, CodingKey {
        case emergency, language
        case chiefComplaint = "chief_complaint"
        case chiefComplaintPatientWords = "chief_complaint_patient_words"
        case duration
        case severity0To10 = "severity_0_10"
        case associated
        case selfMedication = "self_medication"
        case service
        case serviceConfidence = "service_confidence"
        case summaryForNurse = "summary_for_nurse"
        case refillRequest = "refill_request"
        case questionsAsked = "questions_asked"
        case deniedRedFlags = "denied_red_flags"
        case patientConcerns = "patient_concerns"
    }

    /// `validate_intake`: strip, length limits in code points, the score and question ranges, and
    /// the service and language sets.
    public static func validate(_ draft: IntakeDraft) throws -> IntakeRecord {
        let simulated = RuleTables.shared.simulated

        func bounded(_ text: String, _ field: String, max limit: Int) throws -> String {
            let stripped = RuleTables.shared.unicode.stripIntake(text.scalars)
            guard !stripped.isEmpty, stripped.count <= limit else {
                throw IntakeParseError(message: "Invalid intake: \(field) is empty or too long")
            }
            return stripped.string
        }

        guard simulated.languages.contains(draft.language.scalars) else {
            throw IntakeParseError(message: "Invalid intake: language")
        }
        guard simulated.services.contains(draft.service.scalars), let service = Service(rawValue: draft.service)
        else {
            throw IntakeParseError(message: "Invalid intake: service")
        }
        if let severity = draft.severity0To10, !(0...10).contains(severity) {
            throw IntakeParseError(message: "Invalid intake: severity_0_10")
        }
        guard (0...1).contains(draft.serviceConfidence) else {
            throw IntakeParseError(message: "Invalid intake: service_confidence")
        }
        guard (0...simulated.maxQuestions).contains(draft.questionsAsked) else {
            throw IntakeParseError(message: "Invalid intake: questions_asked")
        }
        return IntakeRecord(
            emergency: draft.emergency,
            language: draft.language,
            chiefComplaint: try bounded(draft.chiefComplaint, "chief_complaint", max: simulated.maxComplaint),
            chiefComplaintPatientWords: try bounded(
                draft.chiefComplaintPatientWords, "chief_complaint_patient_words",
                max: simulated.maxPatientWords),
            duration: draft.duration,
            severity0To10: draft.severity0To10,
            associated: draft.associated,
            selfMedication: draft.selfMedication,
            service: service,
            serviceConfidence: draft.serviceConfidence,
            summaryForNurse: try bounded(draft.summaryForNurse, "summary_for_nurse", max: simulated.maxSummary),
            refillRequest: draft.refillRequest,
            questionsAsked: draft.questionsAsked,
            deniedRedFlags: draft.deniedRedFlags,
            patientConcerns: draft.patientConcerns)
    }

    /// `patient_intake`: the record without the free text a patient must not see. The summary for
    /// the nurse, the complaint, the duration, the associated list and the concerns all stay out.
    public var patientView: Intake {
        Intake(
            emergency: emergency,
            language: language,
            chiefComplaintPatientWords: chiefComplaintPatientWords,
            severity0To10: severity0To10,
            selfMedication: selfMedication,
            service: service,
            serviceConfidence: serviceConfidence,
            refillRequest: refillRequest.map(RefillRequest.medicine),
            questionsAsked: questionsAsked,
            deniedRedFlags: deniedRedFlags)
    }

    /// What `summary_reply` reads.
    public var readBackFacts: ReadBackFacts {
        ReadBackFacts(
            chiefComplaint: chiefComplaint, chiefComplaintPatientWords: chiefComplaintPatientWords,
            duration: duration, severity0To10: severity0To10, selfMedication: selfMedication,
            deniedRedFlags: deniedRedFlags)
    }
}

/// The part of an intake the read-back is built from.
public struct ReadBackFacts: Sendable {
    public var chiefComplaint: String
    public var chiefComplaintPatientWords: String
    public var duration: String?
    public var severity0To10: Int?
    public var selfMedication: [String]
    public var deniedRedFlags: [String]

    public init(
        chiefComplaint: String, chiefComplaintPatientWords: String, duration: String?,
        severity0To10: Int?, selfMedication: [String], deniedRedFlags: [String]
    ) {
        self.chiefComplaint = chiefComplaint
        self.chiefComplaintPatientWords = chiefComplaintPatientWords
        self.duration = duration
        self.severity0To10 = severity0To10
        self.selfMedication = selfMedication
        self.deniedRedFlags = deniedRedFlags
    }
}
