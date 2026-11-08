import Foundation

/// The four pill tones a status can take. The app maps each one onto its design tokens.
public enum StatusTone: Sendable, Equatable, CaseIterable {
    case positive, negative, warning, neutral
}

/// What tapping an open visit on S03 does.
public enum OpenVisitAction: Sendable, Equatable {
    /// Today's emergency: S06, straight away, as the visit's own gate would send it.
    case emergency(visitId: String)
    /// `/visit/:id`, which goes on to the visit's canonical screen.
    case visit(visitId: String)
}

/// The list rules of S03 and S12. The ports of the helpers in
/// frontend/src/pages/patient/Home.tsx and History.tsx, so the screens hold no rule of their own.
public enum VisitRules {
    /// `FLAGGED_ALLERGY` in Home.tsx: the one allergy S03 marks as a warning.
    public static let flaggedAllergy = "penicillin"

    /// `NOT_LINKS` in History.tsx: rows that are an end in themselves, with nothing to open.
    public static let historyDeadEnds: Set<VisitStatus> = [
        .redirectedEmergency, .deflectedRefill, .expired, .cancelled,
    ]

    /// `isEmergencyToday`: the same day the server refuses a new check-in, counted in Doha, so
    /// an old emergency does not stay open. A stamp that cannot be read is not today.
    public static func isEmergencyToday(_ row: VisitRow, now: Date) -> Bool {
        guard row.status == .redirectedEmergency, let created = ClinicTime.parse(row.createdAt)
        else { return false }
        return ClinicTime.dohaDay(created) == ClinicTime.dohaDay(now)
    }

    /// `isOpen`: what S03 lists under `home.openVisits`.
    public static func isOpen(_ row: VisitRow, now: Date) -> Bool {
        row.active || row.status == .intake || row.status == .expired
            || isEmergencyToday(row, now: now)
    }

    /// The open rows, in the order the clinic gave them.
    public static func openVisits(_ rows: [VisitRow], now: Date) -> [VisitRow] {
        rows.filter { isOpen($0, now: now) }
    }

    /// `toneOf` in Home.tsx.
    public static func homeTone(_ status: VisitStatus) -> StatusTone {
        switch status {
        case .redirectedEmergency: .negative
        case .expired: .warning
        default: .neutral
        }
    }

    /// `TONES` in History.tsx, with neutral for every status it leaves out.
    public static func historyTone(_ status: VisitStatus) -> StatusTone {
        switch status {
        case .completed: .positive
        case .redirectedEmergency: .negative
        case .expired: .warning
        default: .neutral
        }
    }

    /// Tapping an open visit on S03. An emergency row opens S06 directly, never a chat.
    public static func openAction(_ row: VisitRow) -> OpenVisitAction {
        row.status == .redirectedEmergency
            ? .emergency(visitId: row.visitId) : .visit(visitId: row.visitId)
    }

    /// `hrefOf` in History.tsx: S11 for a completed visit, the visit for one still going, and
    /// nothing for a row that ended elsewhere.
    public static func historyRoute(_ row: VisitRow) -> Route? {
        if historyDeadEnds.contains(row.status) { return nil }
        if row.status == .completed { return .visit(id: row.visitId, screen: .complete) }
        return .visitRoot(id: row.visitId)
    }

    /// The detail line of an S12 row: the parts that exist, joined with ` · `.
    public static func detailLine(_ parts: [String?]) -> String {
        parts.compactMap { part in
            guard let part, !part.isEmpty else { return nil }
            return part
        }
        .joined(separator: " · ")
    }

    /// Whether S03 shows this allergy as the warning pill. Case does not matter, as on the web.
    public static func isFlaggedAllergy(_ allergy: String) -> Bool {
        allergy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == flaggedAllergy
    }
}
