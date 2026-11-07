/// `Suggestion` in backend/ai/doctors.py.
public struct DoctorSuggestion: Sendable, Equatable {
    public var doctorId: String
    public var name: String
    public var counterId: String
    public var counterLabel: String
    public var clinic: String
    public var waiting: Int
    public var speaksLanguage: Bool
    public var genderOk: Bool
    public var score: Double
    public var clinicFallback: Bool
    public var reasonEn: String
    public var reasonAr: String
}

/// Port of backend/ai/doctors.py: doctor suggestion by rule score. The nurse confirms, and the
/// reason is a template.
public enum DoctorRules {
    private struct Candidate {
        let doctor: StaffRecord
        let counter: CounterRecord
        let waiting: Int
    }

    /// `_CANDIDATES`. A doctor counter is what "on shift" means in this demo.
    private static func candidates(
        _ state: ClinicState, centreId: String, clinic: String
    ) -> [Candidate] {
        state.staff
            .filter { $0.role == "doctor" && $0.centreId == centreId && $0.clinic == clinic }
            .flatMap { doctor in
                state.counters
                    .filter {
                        $0.staffId == doctor.id && $0.centreId == doctor.centreId
                            && $0.stage == .doctor
                    }
                    .map { counter in
                        let waiting = state.tickets.count {
                            $0.counterId == counter.id
                                && ($0.state == .active || $0.state == .called
                                    || $0.state == .serving)
                        }
                        return Candidate(doctor: doctor, counter: counter, waiting: waiting)
                    }
            }
    }

    private static func reasonEn(
        _ row: Candidate, lang: String, speaks: Bool, genderOk: Bool, missingService: String?
    ) -> String {
        let text = ClinicData.bundled.text
        let templates = text.templates.doctorReason.en
        let clinic = row.doctor.clinic ?? ""
        var reason = ClinicText.fill(
            speaks ? templates.speaks : templates.notSpeaks,
            [
                "name": row.doctor.name,
                "clinic": text.doctors.clinicEn.value(for: clinic) ?? clinic,
                "waiting": String(row.waiting),
                "language": text.doctors.languageEn.value(for: lang) ?? lang,
            ])
        if !genderOk { reason += templates.genderSuffix }
        if let missingService {
            let label = text.doctors.missingClinicEn.value(for: missingService)
                ?? templates.missingDefaultLabel
            reason += ClinicText.fill(templates.missingSuffix, ["label": label])
        }
        return reason
    }

    private static func reasonAr(
        _ row: Candidate, lang: String, speaks: Bool, genderOk: Bool, missingService: String?
    ) -> String {
        let text = ClinicData.bundled.text
        let templates = text.templates.doctorReason.ar
        let clinic = row.doctor.clinic ?? ""
        // Every gender but F takes the default verb, which the M template holds.
        let gender = row.doctor.gender == "F" ? "F" : "M"
        let sentence = (speaks ? templates.speaks : templates.notSpeaks)[gender] ?? ""
        var reason = ClinicText.fill(
            sentence,
            [
                "name": row.doctor.name,
                "clinic": text.doctors.clinicAr.value(for: clinic) ?? clinic,
                "waiting": String(row.waiting),
                "language": text.doctors.languageAr.value(for: lang) ?? lang,
            ])
        if !genderOk { reason += templates.genderSuffix }
        if let missingService {
            let label = text.doctors.missingClinicAr.value(for: missingService)
                ?? templates.missingDefaultLabel
            reason += ClinicText.fill(templates.missingSuffix, ["label": label])
        }
        return reason
    }

    private static func suggestion(
        _ row: Candidate, patientLang: String, genderPref: String?, missingService: String?
    ) -> DoctorSuggestion {
        let speaks = row.doctor.languages.contains(patientLang)
        let genderOk = genderPref == nil || row.doctor.gender == genderPref
        let score = Double(row.waiting) + (speaks ? 0 : 2) + (genderOk ? 0 : 5)
        return DoctorSuggestion(
            doctorId: row.doctor.id, name: row.doctor.name, counterId: row.counter.id,
            counterLabel: row.counter.label, clinic: row.doctor.clinic ?? "",
            waiting: row.waiting, speaksLanguage: speaks, genderOk: genderOk, score: score,
            clinicFallback: missingService != nil,
            reasonEn: reasonEn(
                row, lang: patientLang, speaks: speaks, genderOk: genderOk,
                missingService: missingService),
            reasonAr: reasonAr(
                row, lang: patientLang, speaks: speaks, genderOk: genderOk,
                missingService: missingService))
    }

    /// Lowest score first. With no doctor in that clinic, the centre's GPs instead. One line
    /// per doctor: a doctor with two counters shows the better one.
    public static func suggest(
        _ state: ClinicState, centreId: String, service: String, patientLang: String,
        genderPref: String? = nil, limit: Int = 3
    ) -> [DoctorSuggestion] {
        var rows = candidates(state, centreId: centreId, clinic: service)
        var missingService: String?
        if rows.isEmpty {
            rows = candidates(state, centreId: centreId, clinic: "gp")
            missingService = service
        }
        let ranked = rows
            .map {
                suggestion(
                    $0, patientLang: patientLang, genderPref: genderPref,
                    missingService: missingService)
            }
            .sorted {
                ($0.score, $0.waiting, $0.doctorId, $0.counterId)
                    < ($1.score, $1.waiting, $1.doctorId, $1.counterId)
            }
        var best: [DoctorSuggestion] = []
        for suggestion in ranked where !best.contains(where: { $0.doctorId == suggestion.doctorId }) {
            best.append(suggestion)
        }
        return Array(best.prefix(limit))
    }
}
