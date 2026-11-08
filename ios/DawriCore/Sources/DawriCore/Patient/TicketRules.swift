import Foundation

/// The rules of S08 to S11, so the screens hold none of their own. The ports of
/// frontend/src/features/ticket/countdown.ts and the helpers in
/// frontend/src/pages/patient/Centre.tsx, Reserved.tsx, Ticket.tsx and Complete.tsx.
public enum TicketRules {
    /// `GEOFENCE_M` in Reserved.tsx: how near the centre "check with my location" works.
    public static let geofenceMetres = 150

    /// `EXPIRY_RETRY_MS` in Reserved.tsx: at 00:00 the visit is read again this often, because
    /// reading it is what runs the expiry, and the phone's clock may be ahead of the clinic's.
    public static let expiryRetry = Duration.seconds(5)

    /// `POLLING_NOTICE_DELAY_MS` in Ticket.tsx: a stream takes a moment to open on every visit,
    /// and that is not a slow connection.
    public static let pollingNoticeDelay = Duration.milliseconds(1_500)

    /// `ON_SCREEN` in Ticket.tsx: the ticket states S10 shows a number and figures for.
    public static let statesOnScreen: Set<TicketState> = [.active, .called, .serving]

    // The countdown

    /// `secondsLeft`: whole seconds left, rounded up and never below 0. Nil when the clinic gave
    /// no usable time, which S09 shows as a dash.
    public static func secondsLeft(_ expiresAt: String?, now: Date) -> Int? {
        guard let expiresAt, let end = ClinicTime.parse(expiresAt) ?? Timestamp.date(from: expiresAt)
        else { return nil }
        let left = end.timeIntervalSince(now)
        return max(0, Int(left.rounded(.up)))
    }

    /// `formatCountdown`: minutes and seconds, each padded to two digits, so 45:00 and 00:09.
    /// Always Latin digits, whatever the language.
    public static func formatCountdown(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        return "\(pad(clamped / 60)):\(pad(clamped % 60))"
    }

    // S10

    /// `ticket` in Ticket.tsx: the visit's ticket while it is one S10 shows. Anything else, or a
    /// ticket without a number, leaves `ticket.nextStep` in the block.
    public static func shownTicket(_ visit: Visit) -> Ticket? {
        guard let ticket = visit.ticket, statesOnScreen.contains(ticket.state) else { return nil }
        return ticket
    }

    /// One row of the figures under the ticket block.
    public enum TicketRow: Sendable, Equatable, CaseIterable {
        case peopleAhead, estimatedWait, goTo
    }

    /// `TicketDetail` in Ticket.tsx. Active shows all three. Serving keeps only where to go.
    /// Called shows none, because the called block already says where to go.
    public static func rows(for state: TicketState) -> [TicketRow] {
        switch state {
        case .active: [.peopleAhead, .estimatedWait, .goTo]
        case .serving: [.goTo]
        default: []
        }
    }

    /// The dependent a visit is for, or nil when it is the patient's own, as Ticket.tsx finds it.
    public static func dependent(of visit: Visit, in me: Me?) -> Patient? {
        me?.dependents.first { $0.id == visit.patientId }
    }

    /// `clock` in Ticket.tsx: the time in Doha as `HH:MM:SS`, on a 24-hour clock with Latin
    /// digits in both languages. Doha is +03:00 all year, so this needs no time zone database.
    public static func dohaClock(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970.rounded(.down)) + 3 * 3_600
        let ofDay = ((seconds % 86_400) + 86_400) % 86_400
        return "\(pad(ofDay / 3_600)):\(pad(ofDay / 60 % 60)):\(pad(ofDay % 60))"
    }

    // S11

    /// `splitLine` in Complete.tsx. The clinic writes "name: how to take it", so the part before
    /// the first colon heads the line. With no colon the medicine's name heads it.
    public static func splitLine(_ medicine: MedicineLine) -> (heading: String, directions: String) {
        guard let colon = medicine.line.firstIndex(of: ":") else {
            return (medicine.name, medicine.line)
        }
        let heading = String(medicine.line[..<colon])
        let directions = medicine.line[medicine.line.index(after: colon)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (heading, directions)
    }

    /// `visit.medicines[lang]`.
    public static func medicines(_ visit: Visit, lang: Lang) -> [MedicineLine] {
        lang == .ar ? visit.medicines.ar : visit.medicines.en
    }

    // S08

    /// The list with the registered centre first, keeping the clinic's order otherwise.
    public static func ordered(_ centres: [CentreOption]) -> [CentreOption] {
        centres.filter(\.registered) + centres.filter { !$0.registered }
    }

    /// `selectedId` in Centre.tsx: the patient's pick, or the clinic's default, which is the
    /// registered centre when it offers the service.
    public static func selectedId(picked: String?, list: CentreList) -> String? {
        picked ?? list.defaultCentreId
    }

    public static func selected(picked: String?, list: CentreList) -> CentreOption? {
        let id = selectedId(picked: picked, list: list)
        return list.centres.first { $0.id == id }
    }

    /// Whether the suggestion card offers `centre.chooseSuggested`: only when it is not chosen.
    public static func offersSuggestion(_ list: CentreList, picked: String?) -> Bool {
        guard let suggestion = list.suggestion else { return false }
        return suggestion.centreId != selectedId(picked: picked, list: list)
    }

    /// The reason in the screen's language, as the clinic wrote it.
    public static func reason(_ suggestion: CentreSuggestion, lang: Lang) -> String {
        lang == .ar ? suggestion.reasonAr : suggestion.reasonEn
    }

    // Errors on S08 and S09

    /// Where a refused reserve or arrival sends the patient instead of an error line.
    public enum Elsewhere: Sendable, Equatable {
        /// `active_visit`: that visit, through its own gate.
        case visit(id: String)
        /// `emergency_today`: S06, as the cover.
        case emergency(visitId: String)
    }

    /// `active_visit` and `emergency_today` with a `visit_id`, as Centre.tsx follows them.
    public static func elsewhere(after error: any Error) -> Elsewhere? {
        guard let clinic = error as? ClinicError,
              case .string(let id)? = clinic.extra["visit_id"], !id.isEmpty
        else { return nil }
        switch clinic.code {
        case "emergency_today": return .emergency(visitId: id)
        case "active_visit": return .visit(id: id)
        default: return nil
        }
    }

    /// What a refused arrival does on S09, in the order Reserved.tsx checks.
    public enum ArrivalFailure: Sendable, Equatable {
        /// `ticket_expired`: read the visit again, which shows the expired step.
        case refetch
        /// `emergency_today`: S06.
        case emergency(visitId: String)
        /// `too_far` with the distance in whole metres, for `reserved.tooFar`.
        case tooFar(metres: Int)
        /// `wrong_door`: under the door code field.
        case wrongDoor
        /// Anything else: an error block.
        case failed
    }

    public static func arrivalFailure(_ error: any Error) -> ArrivalFailure {
        guard let clinic = error as? ClinicError else { return .failed }
        switch clinic.code {
        case "ticket_expired":
            return .refetch
        case "emergency_today":
            if case .emergency(let id)? = elsewhere(after: clinic) { return .emergency(visitId: id) }
            return .failed
        case "too_far":
            guard case .number(let metres)? = clinic.extra["distance_m"] else { return .failed }
            return .tooFar(metres: Int(metres.rounded()))
        case "wrong_door":
            return .wrongDoor
        default:
            return .failed
        }
    }

    /// The door code as the clinic reads it: trimmed, upper case, with Latin digits, so a code
    /// typed on an Arabic keyboard still matches `DOOR-<centre id>`.
    public static func doorCode(_ typed: String) -> String {
        latinDigits(typed.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
    }

    /// Eastern Arabic and Persian digits as Latin ones.
    public static func latinDigits(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            switch scalar.value {
            case 0x0660...0x0669: Unicode.Scalar(scalar.value - 0x0660 + 0x30) ?? scalar
            case 0x06F0...0x06F9: Unicode.Scalar(scalar.value - 0x06F0 + 0x30) ?? scalar
            default: scalar
            }
        }))
    }

    /// `already_rated`: the visit has a rating, so read it again rather than show an error.
    public static func ratingNeedsRefetch(_ error: any Error) -> Bool {
        (error as? ClinicError)?.code == "already_rated"
    }

    private static func pad(_ value: Int) -> String {
        value < 10 ? "0\(value)" : String(value)
    }
}
