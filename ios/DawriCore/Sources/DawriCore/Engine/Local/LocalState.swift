import Foundation

/// `state["last_turn"]` in backend/ai/session.py: `TurnResult.to_api` plus `emergency_category`.
/// The intake is the patient's view, as it is in the Python.
public struct LastTurn: Sendable, Codable, Equatable {
    public var reply: String
    public var done: Bool
    public var emergency: Bool
    public var intake: Intake?
    public var refill: RefillMedicine?
    public var denied: [String]
    public var aiSource: String
    public var selfHarm: Bool
    public var emergencyCategory: String?

    enum CodingKeys: String, CodingKey {
        case reply, done, emergency, intake, refill, denied
        case aiSource = "ai_source"
        case selfHarm = "self_harm"
        case emergencyCategory = "emergency_category"
    }

    init(
        reply: String, done: Bool, emergency: Bool, intake: Intake?, refill: RefillMedicine?,
        denied: [String], aiSource: String, selfHarm: Bool, emergencyCategory: String?
    ) {
        self.reply = reply
        self.done = done
        self.emergency = emergency
        self.intake = intake
        self.refill = refill
        self.denied = denied
        self.aiSource = aiSource
        self.selfHarm = selfHarm
        self.emergencyCategory = emergencyCategory
    }

    init(_ result: TurnResult) {
        self.init(
            reply: result.reply, done: result.done, emergency: result.emergency,
            intake: result.intake?.patientView, refill: result.refill, denied: result.denied,
            aiSource: result.source, selfHarm: result.selfHarm,
            emergencyCategory: result.emergencyCategory)
    }
}

/// The `intake` row of one visit. `messages`, `denied`, `language` and `lastTurn` are the
/// `transcript` column, `intake` is `json`, which stays nil until an intake is ready.
public struct ChatRecord: Sendable, Codable, Equatable {
    public var messages: [ChatMessage]
    public var denied: [String]
    public var language: String
    public var lastTurn: LastTurn?
    public var intake: IntakeRecord?
    public var confirmedByPatient: Bool

    enum CodingKeys: String, CodingKey {
        case messages, denied, language
        case lastTurn = "last_turn"
        case intake
        case confirmedByPatient = "confirmed_by_patient"
    }

    init(
        messages: [ChatMessage], denied: [String], language: String, lastTurn: LastTurn? = nil,
        intake: IntakeRecord? = nil, confirmedByPatient: Bool = false
    ) {
        self.messages = messages
        self.denied = denied
        self.language = language
        self.lastTurn = lastTurn
        self.intake = intake
        self.confirmedByPatient = confirmedByPatient
    }
}

/// A row of the `session` table. There is no token on the phone, so this is all that is left
/// of it. The phone only ever signs in patients: `kind` is here for `require_patient`.
public struct SessionSubject: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case patient
        case staff
    }

    public var kind: Kind
    public var id: String

    init(kind: Kind, id: String) {
        self.kind = kind
        self.id = id
    }
}

/// Everything on the phone, as one Codable value: what SQLite holds on the server plus the
/// session, the queue day and the demo. See `ClinicStore`.
public struct LocalState: Sendable, Codable, Equatable {
    /// Bump this when the shape or the seed changes. An older file then reseeds.
    public static let currentSchema = 1

    public var schemaVersion: Int
    public var clinic: ClinicState
    public var chats: [String: ChatRecord]
    public var subject: SessionSubject?
    /// The Doha day the queue was seeded for. See `rollOverDay`.
    public var queueDay: String
    /// Whole microseconds, as `ClinicTime` keeps them.
    public var lastTickMicros: Int64
    public var demoRuns: [String: DemoRun]

    /// `_seed` in backend/bootstrap.py, with the load on, as the Dockerfile sets it.
    static func fresh(engine: inout QueueEngine, subject: SessionSubject? = nil) throws -> LocalState {
        let now = engine.clock()
        return LocalState(
            schemaVersion: currentSchema,
            clinic: try ClinicState.fresh(engine: &engine, simulateLoad: true),
            chats: [:], subject: subject, queueDay: ClinicTime.dohaDay(now),
            lastTickMicros: ClinicTime.microseconds(of: now), demoRuns: [:])
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    /// Nil for anything unreadable or from another schema, which the caller reseeds.
    static func decoded(_ data: Data) -> LocalState? {
        guard let state = try? JSONDecoder().decode(LocalState.self, from: data),
              state.schemaVersion == currentSchema
        else { return nil }
        return state
    }
}
