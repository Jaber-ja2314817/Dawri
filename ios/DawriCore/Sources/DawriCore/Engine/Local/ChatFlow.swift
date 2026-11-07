import Foundation

/// The refusals of `SessionError` in backend/ai/session.py, rendered as `_SESSION_ERRORS` in
/// backend/main.py renders them.
extension ClinicError {
    static let visitNotFound = ClinicError(
        status: 404, code: "visit_not_found", message: "No visit has this ID.")
    static let invalidText = ClinicError(
        status: 422, code: "invalid_text", message: "The message is empty or not valid text.")
    static let visitNotInIntake = ClinicError(
        status: 409, code: "visit_not_in_intake", message: "This visit is past the chat stage.")
    static let visitNotDeflected = ClinicError(
        status: 409, code: "visit_not_deflected",
        message: "This visit was not sent to the refill route.")
    /// `unexpected_error` in backend/main.py, for a chat that cannot make a valid intake.
    static let internalError = ClinicError(
        status: 500, code: "internal_error", message: "Something went wrong on our side.")
}

/// Port of backend/ai/session.py for the patient: what the chat route calls. `start_walk_in`,
/// `desk_red_flag` and `staff_view` belong to staff and stay out.
///
/// An actor has no gap for a model to think in, but the order of the checks is kept as written,
/// including the re-read and the second rule check inside `saveTurn`, because that order is
/// what was reviewed and what the goldens hold.
extension LocalState {
    private static let maxText = 2000
    /// `_RULES_ONLY`.
    private static let rulesOnly: [VisitStatus] = [
        .redirectedEmergency, .deflectedRefill, .reserved, .expired,
    ]
    /// `_TAKES_RULES`.
    private static let takesRules: [VisitStatus] = [.intake] + rulesOnly
    /// `_KEEPS_REFUSED`. No staff member is with the patient yet, so a refused message may be
    /// half a cue.
    private static let keepsRefused: [VisitStatus] = [.deflectedRefill, .reserved, .expired]

    private func sessionVisit(_ visitId: String) throws -> VisitRecord {
        guard let visit = clinic.visit(visitId) else { throw ClinicError.visitNotFound }
        return visit
    }

    private func sessionPatient(_ visit: VisitRecord, on: AgeReference) throws -> Patient {
        guard let patient = MockHealth.patient(clinic, id: visit.patientId, on: on) else {
            throw ClinicError.visitNotFound
        }
        return patient
    }

    /// `_new_state`.
    static func newChat(for patient: Patient) -> ChatRecord {
        let preferred = patient.preferredLang.isEmpty ? "ar" : patient.preferredLang
        let language = ClinicText.hasPrefix(preferred, "ar") ? "ar" : "en"
        return ChatRecord(
            messages: [
                ChatMessage(
                    role: .assistant, content: Scripted.opening(lang: language), slot: "complaint")
            ],
            denied: [], language: language)
    }

    /// `_load_state`.
    private func loadChat(_ visitId: String, _ patient: Patient) -> ChatRecord {
        chats[visitId] ?? Self.newChat(for: patient)
    }

    /// `_sticky_emergency`: an emergency never clears, so this replays it with no write.
    private static func stickyEmergency(_ chat: ChatRecord) -> TurnResult {
        let last = chat.lastTurn?.emergency == true ? chat.lastTurn : nil
        let selfHarm = last?.selfHarm ?? false
        let reply = last?.reply ?? ""
        let source = last?.aiSource ?? ""
        return TurnResult(
            reply: reply.isEmpty ? Scripted.emergencyReply(lang: chat.language, selfHarm: selfHarm) : reply,
            done: false, emergency: true, intake: nil, refill: nil, denied: chat.denied,
            source: source.isEmpty ? "rules" : source, emergencyCategory: last?.emergencyCategory,
            selfHarm: selfHarm, language: chat.language, slot: nil, events: [], fired: [])
    }

    /// `_stored_slot`.
    private static func storedSlot(_ result: TurnResult) -> String? {
        result.done || result.emergency || result.refill != nil ? Scripted.notAQuestion : result.slot
    }

    /// `_apply_outcome`. The guarded write is what makes the queue refuse a ticket. `reserved`
    /// is in the guard because a patient with a ticket can still report a red flag, and
    /// `expired` because a patient whose reservation lapsed can reserve again, so only this
    /// status stops that.
    private mutating func applyOutcome(_ visitId: String, _ result: TurnResult) {
        if result.emergency {
            clinic.updateVisit(visitId) {
                if [.intake, .deflectedRefill, .reserved, .expired].contains($0.status) {
                    $0.status = .redirectedEmergency
                }
            }
        } else if result.refill != nil {
            clinic.updateVisit(visitId) {
                if $0.status == .intake {
                    $0.status = .deflectedRefill
                    $0.service = .refill
                }
            }
        } else if result.done, let service = result.intake?.service {
            clinic.updateVisit(visitId) {
                if $0.status == .intake { $0.service = service }
            }
        }
    }

    /// `audit.record`.
    mutating func audit(_ visitId: String?, _ events: [AiEvent], at now: Date) {
        let stamp = ClinicTime.iso(now)
        for event in events {
            clinic.appendEvent(
                visitId: visitId, type: event.type, payload: .object(event.payload), at: stamp)
        }
    }

    /// `_save_turn`.
    private mutating func saveTurn(
        _ visitId: String, _ patient: Patient, _ text: String, _ turn: TurnResult, now: Date
    ) throws -> TurnResult {
        var result = turn
        let status = try sessionVisit(visitId).status
        var chat = loadChat(visitId, patient)
        if !result.emergency {
            // What landed meanwhile can complete a cue this turn never saw.
            result = Receptionist.ruleEmergency(
                text: text, history: chat.messages, patient: patient, denied: chat.denied,
                lang: chat.language) ?? result
        }
        if status == .redirectedEmergency && !result.selfHarm {
            return Self.stickyEmergency(chat)
        }
        if status != .intake && !result.emergency {
            throw ClinicError.visitNotInIntake
        }
        chat.messages += [
            ChatMessage(role: .user, content: text, slot: nil),
            ChatMessage(role: .assistant, content: result.reply, slot: Self.storedSlot(result)),
        ]
        let fired = result.fired.map(\.scalars)
        chat.denied = uniqued((chat.denied + result.denied).map(\.scalars))
            .filter { !fired.contains($0) }
            .map(\.string)
        chat.language = result.language
        chat.lastTurn = LastTurn(result)
        if result.done, let intake = result.intake {
            chat.intake = intake
            chat.confirmedByPatient = false
        }
        chats[visitId] = chat
        audit(visitId, result.events, at: now)
        applyOutcome(visitId, result)
        return result
    }

    /// `_note_refused`: keeps a refused message, so "pain" here can still pair with "chest" next
    /// time.
    private mutating func noteRefused(_ visitId: String, _ patient: Patient, _ text: String) {
        var chat = loadChat(visitId, patient)
        chat.messages.append(ChatMessage(role: .user, content: text, slot: nil))
        chats[visitId] = chat
    }

    /// `_turn_past_intake`: rules still run once intake has ended. On a closed emergency only
    /// self-harm adds anything. Nil means nothing new was said.
    private func turnPastIntake(
        _ status: VisitStatus, _ text: String, _ chat: ChatRecord, _ patient: Patient
    ) -> TurnResult? {
        let hit = Receptionist.ruleEmergency(
            text: text, history: chat.messages, patient: patient, denied: chat.denied,
            lang: chat.language)
        guard let hit, status != .redirectedEmergency || hit.selfHarm else { return nil }
        return hit
    }

    /// `_over_long_turn`. A cue can sit past the cut, so the cut only applies to what is stored.
    private mutating func overLongTurn(
        _ visitId: String, _ message: Scalars, _ chat: ChatRecord, _ patient: Patient, now: Date
    ) throws -> TurnResult {
        let hit = Receptionist.ruleEmergency(
            text: message.string, history: chat.messages, patient: patient, denied: chat.denied,
            lang: chat.language)
        guard let hit else { throw ClinicError.invalidText }
        return try saveTurn(visitId, patient, message.prefixed(Self.maxText).string, hit, now: now)
    }

    /// `handle_message`. The length is code points of the raw text, before the strip.
    mutating func handleMessage(
        visitId: String, text: String, on: AgeReference, now: Date
    ) throws -> TurnResult {
        let visit = try sessionVisit(visitId)
        let message = RuleTables.shared.unicode.strip(text.scalars)
        guard !message.isEmpty else { throw ClinicError.invalidText }
        let overLong = text.unicodeScalars.count > Self.maxText
        if overLong && !Self.takesRules.contains(visit.status) { throw ClinicError.invalidText }
        let patient = try sessionPatient(visit, on: on)
        let chat = loadChat(visitId, patient)
        if overLong { return try overLongTurn(visitId, message, chat, patient, now: now) }

        let words = message.string
        if Self.rulesOnly.contains(visit.status),
           let result = turnPastIntake(visit.status, words, chat, patient) {
            return try saveTurn(visitId, patient, words, result, now: now)
        }
        if visit.status == .redirectedEmergency { return Self.stickyEmergency(chat) }
        if Self.keepsRefused.contains(visit.status) { noteRefused(visitId, patient, words) }
        if visit.status != .intake { throw ClinicError.visitNotInIntake }

        let result: TurnResult
        do {
            result = try Receptionist.runTurn(
                text: words, history: chat.messages, patient: patient, denied: chat.denied,
                lang: chat.language)
        } catch is IntakeParseError {
            throw ClinicError.internalError  // Where the Python raises, the route answers 500.
        }
        return try saveTurn(visitId, patient, words, result, now: now)
    }

    /// `continue_after_refill`: "I still want a visit". The patient goes on as GP.
    @discardableResult
    mutating func continueAfterRefill(
        visitId: String, on: AgeReference, now: Date
    ) throws -> IntakeRecord {
        let visit = try sessionVisit(visitId)
        guard visit.status == .deflectedRefill else { throw ClinicError.visitNotDeflected }
        let patient = try sessionPatient(visit, on: on)
        var chat = loadChat(visitId, patient)
        let deflected = chat.lastTurn?.refill?.medicine ?? ""
        let medicine = deflected.isEmpty ? patient.activeMeds.first ?? "" : deflected
        let gpIntake: IntakeRecord
        do {
            gpIntake = try Scripted.gpIntakeAfterRefill(
                history: chat.messages, patient: patient, medicine: medicine, denied: chat.denied,
                lang: chat.language)
        } catch is IntakeParseError {
            throw ClinicError.internalError
        }
        clinic.updateVisit(visitId) {
            $0.status = .intake
            $0.service = .gp
        }
        chat.intake = gpIntake
        chat.confirmedByPatient = false
        chats[visitId] = chat
        audit(
            visitId, [AiEvent(type: "refill.declined", payload: ["medicine": .string(medicine)])],
            at: now)
        return gpIntake
    }

    /// `red_flag_past_arrival`: the rules read all of a message from a patient already in the
    /// centre, and the cut applies only to what is stored. Taking the visit out of the queue is
    /// the caller's step.
    mutating func redFlagPastArrival(
        visitId: String, message: String, on: AgeReference, now: Date
    ) throws -> TurnResult {
        let visit = try sessionVisit(visitId)
        let text = RuleTables.shared.unicode.strip(message.scalars)
        guard !text.isEmpty else { throw ClinicError.invalidText }
        let patient = try sessionPatient(visit, on: on)
        let chat = loadChat(visitId, patient)
        let hit = Receptionist.ruleEmergency(
            text: text.string, history: chat.messages, patient: patient, denied: chat.denied,
            lang: chat.language)
        guard let hit else { throw ClinicError.visitNotInIntake }
        return try saveTurn(visitId, patient, text.prefixed(Self.maxText).string, hit, now: now)
    }

    /// `history`: read-only, and the patient's view. A visit with no message yet shows the
    /// opening without creating a row.
    func history(visitId: String, on: AgeReference) throws -> (chat: ChatRecord, status: VisitStatus) {
        let visit = try sessionVisit(visitId)
        return (loadChat(visitId, try sessionPatient(visit, on: on)), visit.status)
    }
}
