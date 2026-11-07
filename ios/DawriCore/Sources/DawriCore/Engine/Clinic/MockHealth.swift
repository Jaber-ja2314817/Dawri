import Foundation

/// The moment `age_on` reads. A plain date is taken as that date, an instant as its Doha date.
public enum AgeReference: Sendable, Equatable {
    case day(String)
    case instant(Date)
}

/// Port of backend/mock_health.py: synthetic patients in a FHIR-like shape. `patient` and
/// `record` return nil for an unknown patient, as `findByQid` does.
public enum MockHealth {
    private static func view(_ state: ClinicState, _ row: PatientRecord, on: AgeReference) -> Patient? {
        guard let centre = state.centre(row.registeredCentreId) else { return nil }
        let age: Int
        switch on {
        case .day(let day): age = ClinicTime.ageOn(dob: row.dob, day: day)
        case .instant(let date): age = ClinicTime.ageOn(dob: row.dob, at: date)
        }
        return Patient(
            id: row.id, qidDemo: row.qidDemo, fullNameEn: row.fullNameEn,
            fullNameAr: row.fullNameAr, dob: row.dob, age: age, sex: row.sex,
            preferredLang: row.preferredLang, allergies: row.allergies, chronic: row.chronic,
            activeMeds: row.activeMeds,
            registeredCentre: Centre(id: centre.id, nameEn: centre.nameEn, nameAr: centre.nameAr),
            demo: true)
    }

    public static func findByQid(_ state: ClinicState, qid: String, now: Date) -> Patient? {
        state.patients.first { ClinicText.same($0.qidDemo, qid) }
            .flatMap { view(state, $0, on: .instant(now)) }
    }

    public static func patient(_ state: ClinicState, id: String, on: AgeReference) -> Patient? {
        state.patient(id).flatMap { view(state, $0, on: on) }
    }

    public static func dependents(
        _ state: ClinicState, guardianId: String, on: AgeReference
    ) -> [Patient] {
        let ids = state.dependentLinks.filter { $0.guardianId == guardianId }.map(\.dependentId)
        return state.patients
            .filter { ids.contains($0.id) }
            .sorted { $0.id < $1.id }
            .compactMap { view(state, $0, on: on) }
    }

    public static func demoPatients(_ state: ClinicState) -> [DemoPatient] {
        let dependents = state.dependentLinks.map(\.dependentId)
        return state.patients
            .filter { !dependents.contains($0.id) }
            .sorted { $0.id < $1.id }
            .map {
                DemoPatient(
                    id: $0.id, qidDemo: $0.qidDemo, fullNameEn: $0.fullNameEn,
                    fullNameAr: $0.fullNameAr)
            }
    }

    public static func record(_ state: ClinicState, patientId: String) -> JSONValue? {
        guard let row = state.patient(patientId) else { return nil }
        let reference: JSONValue = .object(["reference": .string("Patient/\(row.id)")])
        func code(_ text: String) -> JSONValue { .object(["text": .string(text)]) }
        func language(_ text: String, _ tag: String) -> JSONValue {
            .object(["text": .string(text), "language": .string(tag)])
        }
        var resources: [JSONValue] = [
            .object([
                "resourceType": .string("Patient"),
                "id": .string(row.id),
                "identifier": .array([
                    .object([
                        "system": .string("urn:dawri:demo-qid"), "value": .string(row.qidDemo),
                    ])
                ]),
                "name": .array([language(row.fullNameEn, "en"), language(row.fullNameAr, "ar")]),
                "gender": .string(row.sex == "F" ? "female" : "male"),
                "birthDate": .string(row.dob),
            ])
        ]
        resources += row.allergies.map { allergy in
            .object([
                "resourceType": .string("AllergyIntolerance"), "patient": reference,
                "code": code(allergy),
            ])
        }
        resources += row.chronic.map { condition in
            .object([
                "resourceType": .string("Condition"), "subject": reference,
                "code": code(condition),
            ])
        }
        resources += row.activeMeds.map { med in
            .object([
                "resourceType": .string("MedicationStatement"), "status": .string("active"),
                "subject": reference, "medicationCodeableConcept": code(med),
            ])
        }
        return .object([
            "resourceType": .string("Bundle"),
            "type": .string("collection"),
            "demo": .bool(true),
            "entry": .array(resources.map { .object(["resource": $0]) }),
        ])
    }
}
