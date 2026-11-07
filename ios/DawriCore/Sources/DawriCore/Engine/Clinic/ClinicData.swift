import Foundation

/// A `[key, value]` row. The exporter writes tables this way to keep Python's source order.
struct ClinicRow<Value: Decodable & Sendable>: Decodable, Sendable {
    let key: String
    let value: Value

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        key = try row.decode(String.self)
        value = try row.decode(Value.self)
    }
}

typealias ClinicTable = [ClinicRow<String>]

extension Array where Element == ClinicRow<String> {
    /// `table.get(key)`, comparing scalars as a Python dict does.
    func value(for key: String) -> String? {
        first { ClinicText.same($0.key, key) }?.value
    }
}

/// Everything the Python modules hold as constants, read from the exported resources. Nothing
/// here is typed by hand. The columns are in the docstring of ios/Tools/export/clinic.py.
public struct ClinicData: Sendable {
    let tables: Tables
    let constants: Constants
    let text: Text

    /// The package's own resources, so a failure here is a broken build, not a runtime case.
    public static let bundled: ClinicData = {
        do {
            return try ClinicData(
                seed: try resource("engine.clinic.seed"), text: try resource("engine.clinic.text"))
        } catch {
            preconditionFailure("Invalid bundled clinic resource: \(error)")
        }
    }()

    init(seed: Data, text: Data) throws {
        let decoder = JSONDecoder()
        let file = try decoder.decode(SeedFile.self, from: seed)
        tables = file.seed
        constants = file.constants
        self.text = try decoder.decode(Text.self, from: text)
    }

    static func resource(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    struct Tables: Decodable, Sendable {
        let centres: [CentreRecord]
        let counters: [CounterRecord]
        let dependents: [DependentLink]
        let doctors: [StaffRecord]
        let drugs: [DrugRecord]
        let patients: [PatientRecord]
        let staff: [StaffRecord]
    }

    struct SeedFile: Decodable {
        let seed: Tables
        let constants: Constants

        enum CodingKeys: String, CodingKey { case seed }

        init(from decoder: any Decoder) throws {
            seed = try decoder.container(keyedBy: CodingKeys.self).decode(Tables.self, forKey: .seed)
            constants = try Constants(from: decoder)
        }
    }

    struct Constants: Decodable, Sendable {
        let nextRealNumber: [ClinicRow<[ClinicRow<Int>]>]
        let simulatedTickets: [ClinicRow<Int>]
        let protectedCentres: [String]
        let reservationMinutes: Int
        let noShowLimit: Int
        let rollingWindow: Int
        let minRollingSamples: Int
        let minSampleSec: Int
        let geofenceM: Int
        let nearKm: Int
        let muchShorterMin: Int
        let simulateIntervalSec: Int
        let demoOtp: String
        let reservableStatuses: [VisitStatus]
        let noTicketStatuses: [VisitStatus]
        let simulatedNote: String
        let activeStatuses: [VisitStatus]
        let atTheCentre: [VisitStatus]
        let atACounter: [TicketState]
        let gpRouted: [String]
        let earthRadiusM: Double

        enum CodingKeys: String, CodingKey {
            case nextRealNumber = "NEXT_REAL_NUMBER"
            case simulatedTickets = "SIMULATED_TICKETS"
            case protectedCentres = "PROTECTED_CENTRES"
            case reservationMinutes = "RESERVATION_MINUTES"
            case noShowLimit = "NO_SHOW_LIMIT"
            case rollingWindow = "ROLLING_WINDOW"
            case minRollingSamples = "MIN_ROLLING_SAMPLES"
            case minSampleSec = "MIN_SAMPLE_SEC"
            case geofenceM = "GEOFENCE_M"
            case nearKm = "NEAR_KM"
            case muchShorterMin = "MUCH_SHORTER_MIN"
            case simulateIntervalSec = "SIMULATE_INTERVAL_SEC"
            case demoOtp = "DEMO_OTP"
            case reservableStatuses = "RESERVABLE_STATUSES"
            case noTicketStatuses = "NO_TICKET_STATUSES"
            case simulatedNote = "_SIMULATED_NOTE"
            case activeStatuses = "ACTIVE_STATUSES"
            case atTheCentre = "_AT_THE_CENTRE"
            case atACounter = "_AT_A_COUNTER"
            case gpRouted = "_GP_ROUTED"
            case earthRadiusM = "_EARTH_RADIUS_M"
        }
    }

    struct Text: Decodable, Sendable {
        let medicines: Medicines
        let doctors: Doctors
        let visitFlow: VisitFlowText
        let visits: Visits
        let templates: Templates

        enum CodingKeys: String, CodingKey {
            case medicines, doctors, visits, templates
            case visitFlow = "visit_flow"
        }

        struct Medicines: Decodable, Sendable {
            let frequencyEn: ClinicTable
            let frequencyAr: ClinicTable
            let formAr: ClinicTable
            let unitAr: ClinicTable

            enum CodingKeys: String, CodingKey {
                case frequencyEn = "_FREQUENCY_EN"
                case frequencyAr = "_FREQUENCY_AR"
                case formAr = "_FORM_AR"
                case unitAr = "_UNIT_AR"
            }
        }

        struct Doctors: Decodable, Sendable {
            let clinicEn: ClinicTable
            let clinicAr: ClinicTable
            let languageEn: ClinicTable
            let languageAr: ClinicTable
            let missingClinicEn: ClinicTable
            let missingClinicAr: ClinicTable

            enum CodingKeys: String, CodingKey {
                case clinicEn = "_CLINIC_EN"
                case clinicAr = "_CLINIC_AR"
                case languageEn = "_LANGUAGE_EN"
                case languageAr = "_LANGUAGE_AR"
                case missingClinicEn = "_MISSING_CLINIC_EN"
                case missingClinicAr = "_MISSING_CLINIC_AR"
            }
        }

        struct VisitFlowText: Decodable, Sendable {
            let allergenAr: ClinicTable

            enum CodingKeys: String, CodingKey { case allergenAr = "_ALLERGEN_AR" }
        }

        struct Visits: Decodable, Sendable {
            let staffRouteEn: String
            let staffRouteAr: String
            let checkInEn: String
            let checkInAr: String

            enum CodingKeys: String, CodingKey {
                case staffRouteEn = "STAFF_ROUTE_EN"
                case staffRouteAr = "STAFF_ROUTE_AR"
                case checkInEn = "CHECK_IN_EN"
                case checkInAr = "CHECK_IN_AR"
            }
        }

        struct Templates: Decodable, Sendable {
            let doctorReason: DoctorReason
            let suggestionReason: Bilingual
            let allergy: Bilingual
            let medicineDays: MedicineDays
            let medicineLine: MedicineLine

            enum CodingKeys: String, CodingKey {
                case doctorReason = "doctor_reason"
                case suggestionReason = "suggestion_reason"
                case allergy
                case medicineDays = "medicine_days"
                case medicineLine = "medicine_line"
            }
        }

        struct Bilingual: Decodable, Sendable {
            let en: String
            let ar: String
        }

        struct DoctorReason: Decodable, Sendable {
            let en: English
            let ar: Arabic

            struct English: Decodable, Sendable {
                let speaks: String
                let notSpeaks: String
                let genderSuffix: String
                let missingSuffix: String
                let missingDefaultLabel: String

                enum CodingKeys: String, CodingKey {
                    case speaks
                    case notSpeaks = "not_speaks"
                    case genderSuffix = "gender_suffix"
                    case missingSuffix = "missing_suffix"
                    case missingDefaultLabel = "missing_default_label"
                }
            }

            /// `speaks` and `not_speaks` come per gender, F and M.
            struct Arabic: Decodable, Sendable {
                let speaks: [String: String]
                let notSpeaks: [String: String]
                let genderSuffix: String
                let missingSuffix: String
                let missingDefaultLabel: String

                enum CodingKeys: String, CodingKey {
                    case speaks
                    case notSpeaks = "not_speaks"
                    case genderSuffix = "gender_suffix"
                    case missingSuffix = "missing_suffix"
                    case missingDefaultLabel = "missing_default_label"
                }
            }
        }

        struct MedicineDays: Decodable, Sendable {
            let enOne: String
            let enMany: String
            let arOne: String
            let arTwo: String
            let arFew: String
            let arMany: String
            let arManyFrom: Int

            enum CodingKeys: String, CodingKey {
                case enOne = "en_one"
                case enMany = "en_many"
                case arOne = "ar_one"
                case arTwo = "ar_two"
                case arFew = "ar_few"
                case arMany = "ar_many"
                case arManyFrom = "ar_many_from"
            }
        }

        struct MedicineLine: Decodable, Sendable {
            let en: String
            let ar: String
            let bare: String
            let joiner: Bilingual
        }
    }
}
