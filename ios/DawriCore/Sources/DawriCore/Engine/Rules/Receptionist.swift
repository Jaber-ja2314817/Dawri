/// A record of something a turn did. Staff read these in the event log.
public struct AiEvent: Sendable, Equatable {
    public let type: String
    public let payload: [String: JSONValue]

    public init(type: String, payload: [String: JSONValue]) {
        self.type = type
        self.payload = payload
    }
}

/// `TurnResult` in backend/ai/receptionist.py. `source` is rules or simulated: this app has no model.
public struct TurnResult: Sendable {
    public let reply: String
    public let done: Bool
    public let emergency: Bool
    public let intake: IntakeRecord?
    public let refill: RefillMedicine?
    public let denied: [String]
    public let source: String
    public let emergencyCategory: String?
    public let selfHarm: Bool
    public let language: String
    public let slot: String?
    public let events: [AiEvent]
    /// Labels that may not stay denied.
    public let fired: [String]

    /// `to_api`. `status`, the transcript and the nearest emergency department are the session's.
    public func toAPI(status: VisitStatus, transcript: String? = nil, nearestEd: NearestEd? = nil) -> ChatResponse {
        ChatResponse(
            reply: reply, done: done, emergency: emergency, intake: intake?.patientView, refill: refill,
            denied: denied, aiSource: source, selfHarm: selfHarm, status: status, transcript: transcript,
            nearestEd: nearestEd)
    }
}

/// One receptionist turn: rules first, then the scripted flow. The order is fixed. Red-flag rules
/// run on every message and a hit stops the chat. There is no model on the phone, so this is
/// `run_turn` with an llm whose mode is simulated.
public enum Receptionist {
    private static let sourceRules = "rules"
    private static let sourceSimulated = "simulated"

    /// What a turn knows once the rules have cleared the message.
    private struct Turn {
        let text: Scalars
        let history: [ChatLine]
        let patient: Patient
        let denied: [Scalars]
        let language: Scalars
        var events: [AiEvent]
        let fired: [String]

        var asked: Int { Scripted.questionCount(history) }
        var conversation: [ChatLine] { history + [ChatLine(user: text)] }
        var said: [Scalars] { conversation.filter { !$0.isAssistant }.map(\.content) }

        /// A symptom or a medicine problem anywhere in the chat must reach a nurse.
        var refillBlocked: Bool {
            said.contains { Refill.blocksRefill(TextRules.tokenise($0)) }
        }

        func result(
            _ reply: String, source: String, slot: String? = nil, done: Bool = false,
            intake: IntakeRecord? = nil, refill: RefillMedicine? = nil, emergency: Bool = false,
            category: String? = nil, selfHarm: Bool = false
        ) -> TurnResult {
            let isQuestion = !(done || emergency || refill != nil)
            let askedNow = intake?.questionsAsked ?? (asked + (isQuestion ? 1 : 0))
            var all = events
            all.append(
                AiEvent(
                    type: "ai.turn",
                    payload: [
                        "source": .string(source), "questions_asked": .number(Double(askedNow)),
                        "done": .bool(done),
                    ]))
            if done, let intake {
                all.append(
                    AiEvent(
                        type: "ai.intake_ready",
                        payload: ["service": .string(intake.service.rawValue), "source": .string(source)]))
            }
            return TurnResult(
                reply: reply, done: done, emergency: emergency, intake: intake, refill: refill,
                denied: denied.map(\.string), source: source, emergencyCategory: category,
                selfHarm: selfHarm, language: language.string, slot: slot, events: all, fired: fired)
        }
    }

    private static func deflect(_ turn: Turn, medicine: String, source: String) -> TurnResult {
        var turn = turn
        turn.events.append(AiEvent(type: "refill.detected", payload: ["medicine": .string(medicine)]))
        return turn.result(
            Scripted.refillReply(medicine: medicine, lang: turn.language.string), source: source,
            refill: RefillMedicine(medicine: medicine))
    }

    private static func ruleEmergency(_ turn: Turn, _ flags: RedFlagResult) -> TurnResult {
        turn.result(
            Scripted.emergencyReply(lang: turn.language.string, selfHarm: flags.selfHarm),
            source: sourceRules, emergency: true, category: flags.categories.first, selfHarm: flags.selfHarm)
    }

    private static func simulatedTurn(_ turn: Turn) throws -> TurnResult {
        let scripted = try Scripted.nextTurn(
            turn.conversation, turn.patient, denied: turn.denied, lang: turn.language)
        return turn.result(
            scripted.reply, source: sourceSimulated, slot: scripted.slot, done: scripted.intake != nil,
            intake: scripted.intake)
    }

    private static func readRules(
        _ text: Scalars, _ history: [ChatLine], _ patient: Patient, denied: [String]?, lang: String?
    ) -> (Turn, RedFlagResult) {
        let current: Scalars
        if let lang, !lang.scalars.isEmpty {
            current = lang.scalars
        } else if !patient.preferredLang.scalars.isEmpty {
            current = patient.preferredLang.scalars
        } else {
            current = LanguageKey.en.scalars
        }
        let language = Scripted.detectLang(text, current: current)
        let flags = RedFlags.checkConversation(text, history: history)
        let newDenied = flags.denied.map(\.labelEn)
        var events = flags.hits.map { hit in
            AiEvent(
                type: "redflag.hit",
                payload: [
                    "category": .string(hit.category), "cue": .string(hit.cue), "label": .string(hit.labelEn),
                ])
        }
        if !newDenied.isEmpty {
            events.append(
                AiEvent(type: "redflag.denied", payload: ["labels": .array(newDenied.map(JSONValue.string))]))
        }
        let merged = uniqued((denied ?? []).map(\.scalars) + newDenied.map(\.scalars))
        let turn = Turn(
            text: text, history: history, patient: patient,
            denied: merged.filter { !flags.firedLabels.contains($0) }, language: language, events: events,
            fired: flags.fired)
        return (turn, flags)
    }

    /// Rules alone, for a visit past intake: the emergency turn on a hit, else nil.
    public static func ruleEmergency(
        text: String, history: [ChatMessage], patient: Patient, denied: [String]? = nil, lang: String? = nil
    ) -> TurnResult? {
        let (turn, flags) = readRules(
            text.scalars, history.map(ChatLine.init), patient, denied: denied, lang: lang)
        return flags.emergency ? ruleEmergency(turn, flags) : nil
    }

    /// One patient message. `history` does not include `text`, and empty means the opening. It
    /// throws only when the chat cannot make a valid intake, where the Python raises as well.
    public static func runTurn(
        text: String, history: [ChatMessage], patient: Patient, denied: [String]? = nil, lang: String? = nil
    ) throws -> TurnResult {
        let (turn, flags) = readRules(
            text.scalars, history.map(ChatLine.init), patient, denied: denied, lang: lang)
        if flags.emergency { return ruleEmergency(turn, flags) }
        if !turn.refillBlocked, let match = Refill.detect(turn.text, activeMeds: patient.activeMeds) {
            return deflect(turn, medicine: match.medicine, source: sourceRules)
        }
        return try simulatedTurn(turn)
    }
}
