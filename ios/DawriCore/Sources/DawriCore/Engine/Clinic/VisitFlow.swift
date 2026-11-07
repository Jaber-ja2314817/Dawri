import Foundation

/// A conflict `allergy_conflict` found.
public struct AllergyConflict: Sendable, Equatable {
    public var allergen: String
    public var textEn: String
    public var textAr: String
}

/// A row of `allergy_conflicts`.
public struct DrugConflict: Sendable, Equatable {
    public var drugId: String
    public var nameEn: String
    public var conflict: AllergyConflict

    var json: JSONValue {
        .object([
            "drug_id": .string(drugId), "name_en": .string(nameEn),
            "allergen": .string(conflict.allergen),
            "text_en": .string(conflict.textEn), "text_ar": .string(conflict.textAr),
        ])
    }
}

/// A prescription line as it is asked for. Blanks take the drug's defaults.
public struct PrescriptionRequest: Sendable, Equatable {
    public var drugId: String
    public var dose: String?
    public var frequency: String?
    public var days: Int?
    public var notes: String?

    public init(
        drugId: String, dose: String? = nil, frequency: String? = nil, days: Int? = nil,
        notes: String? = nil
    ) {
        self.drugId = drugId
        self.dose = dose
        self.frequency = frequency
        self.days = days
        self.notes = notes
    }
}

public struct ResolvedItem: Sendable, Equatable {
    public var drug: DrugRecord
    public var dose: String?
    public var frequency: String?
    public var days: Int?
    public var notes: String?
}

/// Port of backend/visit_flow.py: leaving the queue on a red flag, the consult and dispensing.
/// Only deterministic rules here: the allergy check is a table lookup, and the demo default
/// list is a fixed seed flag, never a model output.
public enum VisitFlow {
    /// What stops a visit: the rules, the model, or a release by a nurse or a sibling's red flag.
    private static let emergencyEvents = ["redflag.hit", "ai.emergency", "ticket.released"]

    /// This patient's emergency visit of the Doha day of `now`, the newest visit first. The day
    /// is the one the emergency happened on, as a visit opened before midnight can be flagged
    /// after it. The look is keyed on the patient, so a guardian stays free when a dependent is
    /// stopped.
    public static func emergencyToday(
        _ state: ClinicState, patientId: String, now: Date, otherThan: String? = nil
    ) -> String? {
        let visits = state.visits
            .filter {
                $0.patientId == patientId && $0.status == .redirectedEmergency
                    && $0.id != otherThan
            }
            .sorted { first, second in
                first.createdAt != second.createdAt
                    ? first.createdAt > second.createdAt : first.id < second.id
            }
        let today = ClinicTime.dohaDay(now)
        for visit in visits {
            let happened = state.events
                .filter { $0.visitId == visit.id && emergencyEvents.contains($0.type) }
                .map(\.at).max() ?? visit.createdAt
            guard let date = ClinicTime.parse(happened) else { continue }
            if ClinicTime.dohaDay(date) == today { return visit.id }
        }
        return nil
    }

    /// A red flag takes every live ticket of this patient out of the queue, in any stage. The
    /// no-ticket line belongs to the patient, so a ticket on a second visit goes too, and so
    /// does a reservation. A dependent's visit is someone else's. Escalate and not release, so
    /// a reserved patient is not left with an open visit and no ticket.
    public static func leaveTheQueue(
        _ engine: inout QueueEngine, _ state: inout ClinicState, patientId: String
    ) throws {
        var seen: Set<String> = []
        while true {
            let due = engine.liveTicketsOfPatient(state, patientId: patientId)
                .filter { !seen.contains($0.id) }
            if due.isEmpty { return }
            for ticket in due {
                seen.insert(ticket.id)
                do {
                    _ = try engine.escalate(&state, ticketId: ticket.id, reason: "emergency")
                } catch let error as ClinicError where error.code == "invalid_transition" {
                    continue  // It lapsed or moved a moment ago, and the next look finds where.
                }
            }
        }
    }

    /// An unknown term stays as stored: a clinical word is never guessed.
    private static func allergenAr(_ allergy: String) -> String {
        let table = ClinicData.bundled.text.visitFlow.allergenAr
        return table.value(for: ClinicText.lower(ClinicText.strip(allergy))) ?? allergy
    }

    /// The first allergy on the record that this drug hits, or nil. It matches a tag or a
    /// substring of the English name.
    public static func allergyConflict(allergies: [String], drug: DrugRecord) -> AllergyConflict? {
        let tags = drug.allergyTags.map { ClinicText.lower(ClinicText.strip($0)) }
        let name = ClinicText.lower(drug.nameEn)
        let templates = ClinicData.bundled.text.templates.allergy
        for allergy in allergies {
            let key = ClinicText.lower(ClinicText.strip(allergy))
            guard !key.isEmpty else { continue }
            if tags.contains(where: { ClinicText.same($0, key) }) || ClinicText.contains(name, key) {
                return AllergyConflict(
                    allergen: allergy,
                    textEn: ClinicText.fill(
                        templates.en, ["allergen": allergy, "drug": drug.nameEn]),
                    textAr: ClinicText.fill(
                        templates.ar, ["allergen": allergenAr(allergy), "drug": drug.nameAr]))
            }
        }
        return nil
    }

    private static func filled(_ value: String?, default fallback: String?) -> String? {
        let text = ClinicText.strip(value ?? "")
        return text.isEmpty ? fallback : text
    }

    /// Each line against the drug table, blanks taking the drug's defaults. An id is required
    /// because a typed name would never meet the allergy check.
    public static func resolveItems(_ state: ClinicState, items: [PrescriptionRequest]) throws
        -> [ResolvedItem]
    {
        try items.map { item in
            guard let drug = state.drugs.first(where: { $0.id == item.drugId }) else {
                throw ClinicError(
                    status: 422, code: "unknown_drug",
                    message: "Pick the medicine from the drug list.")
            }
            return ResolvedItem(
                drug: drug, dose: filled(item.dose, default: drug.defaultDose),
                frequency: filled(item.frequency, default: drug.defaultFrequency),
                days: item.days ?? drug.defaultDays, notes: filled(item.notes, default: nil))
        }
    }

    public static func allergyConflicts(allergies: [String], items: [ResolvedItem]) -> [DrugConflict] {
        items.compactMap { item in
            allergyConflict(allergies: allergies, drug: item.drug).map {
                DrugConflict(drugId: item.drug.id, nameEn: item.drug.nameEn, conflict: $0)
            }
        }
    }

    /// The demo prescription, without anything that conflicts with this patient's record.
    public static func defaultItems(_ state: ClinicState, allergies: [String]) throws -> [ResolvedItem] {
        let ids = state.drugs.filter { $0.demoDefault == 1 }.map(\.id).sorted()
        let items = try resolveItems(state, items: ids.map { PrescriptionRequest(drugId: $0) })
        return items.filter { allergyConflict(allergies: allergies, drug: $0.drug) == nil }
    }

    public static func pharmacyCounter(_ state: ClinicState, centreId: String) throws -> String {
        let found = state.counters
            .filter { $0.centreId == centreId && $0.stage == .pharmacy }
            .map(\.id).min()
        guard let found else {
            throw ClinicError.invalidTransition("centre \(centreId) has no pharmacy counter")
        }
        return found
    }

    private static func checkAtCounter(_ state: ClinicState, ticket: TicketRecord) throws {
        guard let row = state.ticket(ticket.id) else {
            throw ClinicError.ticketNotFound("no ticket \(ticket.id)")
        }
        guard row.state == .called || row.state == .serving else {
            throw ClinicError.invalidTransition("this patient has not been called to the counter")
        }
    }

    /// Stores the prescription, then moves on: to pharmacy, or out when nothing was prescribed.
    /// `overrides` are the allergy conflicts the doctor acknowledged, logged with the rows.
    /// The stored prescription stands even if the move that follows is refused.
    public static func completeConsult(
        _ engine: inout QueueEngine, _ state: inout ClinicState, visitId: String,
        ticket: TicketRecord, items: [ResolvedItem], actor: String,
        overrides: [DrugConflict] = []
    ) throws -> TicketRecord {
        let pharmacy = items.isEmpty ? nil : try pharmacyCounter(state, centreId: ticket.centreId)
        try checkAtCounter(state, ticket: ticket)
        state.prescriptions.removeAll { $0.visitId == visitId }
        state.prescriptions.append(
            contentsOf: items.map {
                PrescriptionRecord(
                    visitId: visitId, drug: $0.drug.id, dose: $0.dose, frequency: $0.frequency,
                    days: $0.days, notes: $0.notes)
            })
        let stamp = ClinicTime.iso(engine.clock())
        state.appendEvent(
            visitId: visitId, type: "consult.done",
            payload: .object(["staff_id": .string(actor), "items": .optional(items.count)]),
            at: stamp)
        if !overrides.isEmpty {
            state.appendEvent(
                visitId: visitId, type: "prescription.allergy_override",
                payload: .object([
                    "staff_id": .string(actor), "conflicts": .array(overrides.map(\.json)),
                ]),
                at: stamp)
        }
        guard let pharmacy else { return try engine.finishVisit(&state, ticketId: ticket.id) }
        return try engine.advance(&state, ticketId: ticket.id, nextCounterId: pharmacy)
    }

    public static func dispense(
        _ engine: inout QueueEngine, _ state: inout ClinicState, visitId: String,
        ticket: TicketRecord, actor: String
    ) throws -> TicketRecord {
        let finished = try engine.finishVisit(&state, ticketId: ticket.id)
        state.appendEvent(
            visitId: visitId, type: "dispensed", payload: .object(["staff_id": .string(actor)]),
            at: ClinicTime.iso(engine.clock()))
        return finished
    }
}
