import Foundation
import Testing
@testable import DawriCore

/// One row as plain JSON, for files whose rows differ by their first column.
private typealias Row = [JSONValue]

@Suite("Clinic rule goldens")
struct ClinicRuleGoldenTests {
    private static let noon = "2026-11-07T09:00:00+00:00"

    private func item(_ value: JSONValue) throws -> MedicineItem {
        let row = try #require(value.object)
        func days(_ value: JSONValue?) throws -> MedicineDays? {
            switch value {
            case .number(let number)?:
                number == number.rounded() ? .whole(Int(number)) : .decimal(number)
            case .string(let text)?: .text(text)
            case .null?, nil: nil
            default: throw GoldenError.notInManifest("days")
            }
        }
        return MedicineItem(
            drug: row["drug"]?.string, dose: row["dose"]?.string,
            frequency: row["frequency"]?.string, days: try days(row["days"]),
            notes: row["notes"]?.string)
    }

    /// A golden nobody loads proves nothing, so each one must be named by a test here.
    @Test func `every clinic golden is loaded by a test`() throws {
        let folder = "ios/DawriCore/Tests/DawriCoreTests/Clinic"
        let sources = try ["QueueTraceGoldenTests.swift", "ClinicRulesGoldenTests.swift"]
            .map { try Repo.text("\(folder)/\($0)") }
            .joined()
        for file in try Golden.manifest(.clinic).files.keys.sorted() {
            let stem = file.replacingOccurrences(of: ".json", with: "")
            #expect(sources.contains("Golden.load(.clinic, \"\(stem)\""), "\(file)")
        }
    }

    @Test func `medicines match line for line`() throws {
        let golden = try Golden.load(.clinic, "medicines", as: Row.self)
        let ran = try golden.run { row in
            let drug = row[2].isNull ? nil : try goldenDrug(row[2])
            let lang = try #require(row[1].string)
            let line = MedicineLines.plainLine(try item(row[0]), lang: lang, drug: drug)
            let expected = try #require(row[3].string)
            #expect(sameScalars(line, expected), "\(text(row[0])) \(lang)\nfound    \(line)\nexpected \(expected)")
        }
        #expect(ran == golden.count)
    }

    private func doctorState(_ waiting: JSONValue, extraCounter: JSONValue?) throws -> ClinicState {
        let clock = try TestClock(Self.noon)
        var engine = makeEngine(clock)
        var state = ClinicState()
        if let extraCounter {
            let row = try JSONEncoder().encode(extraCounter)
            state.counters.append(try JSONDecoder().decode(CounterRecord.self, from: row))
        }
        for (counter, count) in try #require(waiting.object).sorted(by: { $0.key < $1.key }) {
            for _ in 0..<(try #require(count.int)) {
                _ = try engine.issueSimulated(&state, counterId: counter)
            }
        }
        return state
    }

    @Test func `doctor suggestions match row for row`() throws {
        let golden = try Golden.load(.clinic, "doctors", as: Row.self)
        let extras = try #require(golden.header["extra_counters"]?.object)
        let waiting = try #require(golden.header["states"]?.array)
        let states = try waiting.enumerated().map { index, queue in
            try doctorState(queue, extraCounter: extras[String(index)])
        }
        let ran = try golden.run { row in
            let found = DoctorRules.suggest(
                states[try #require(row[0].int)], centreId: try #require(row[1].string),
                service: try #require(row[2].string), patientLang: try #require(row[3].string),
                genderPref: row[4].string, limit: try #require(row[5].int))
            let shaped: [JSONValue] = found.map { item in
                .array([
                    .string(item.doctorId), .string(item.name), .string(item.counterId),
                    .string(item.counterLabel), .string(item.clinic), .number(item.waiting),
                    .bool(item.speaksLanguage), .bool(item.genderOk), .number(item.score),
                    .bool(item.clinicFallback), .string(item.reasonEn), .string(item.reasonAr),
                ])
            }
            #expect(sameJSON(.array(shaped), row[6]), "\(text(.array(row)))\nfound \(text(.array(shaped)))")
        }
        #expect(ran == golden.count)
    }

    private func option(_ value: JSONValue) throws -> CentreOption {
        let row = try #require(value.object)
        return CentreOption(
            id: try #require(row["id"]?.string), nameEn: try #require(row["name_en"]?.string),
            nameAr: try #require(row["name_ar"]?.string), operator: row["operator"]?.string ?? "",
            lat: try #require(row["lat"]?.double), lng: try #require(row["lng"]?.double),
            waitMin: row["wait_min"]?.int, peopleAhead: row["people_ahead"]?.int,
            distanceKm: row["distance_km"]?.double,
            registered: row["registered"] == .bool(true))
    }

    private func point(_ lat: JSONValue, _ lng: JSONValue) -> GeoPoint? {
        guard let lat = lat.double, let lng = lng.double else { return nil }
        return GeoPoint(lat: lat, lng: lng)
    }

    private func same(_ found: some Encodable, _ expected: JSONValue, _ row: Row) throws {
        let shaped = try plainJSON(found)
        #expect(
            sameJSON(shaped, withoutNulls(expected)),
            "\(text(.array(row)))\nfound \(text(shaped))")
    }

    private func centreRow(
        _ row: Row, states: [ClinicState], engine: QueueEngine
    ) throws {
        let state = states[0]
        switch row[0].string {
        case "list":
            let patient = try #require(row[2].string)
            let service = try #require(row[3].string)
            do {
                let list = try CentreRules.list(
                    states[try #require(row[1].int)], engine: engine, patientId: patient,
                    service: service, lat: row[4].double, lng: row[5].double)
                #expect(row[6].int == 200, "\(text(.array(row)))")
                try same(list, row[7], row)
            } catch let error as ClinicError {
                #expect(row[6].int == error.status, "\(text(.array(row)))")
                #expect(row[7].string == error.code, "\(text(.array(row)))")
            }
        case "routed_service":
            #expect(CentreRules.routedService(try #require(row[1].string)) == row[2].string)
        case "nearest_ed":
            let found = CentreRules.nearestEd(state, patientId: try #require(row[1].string))
            if let found {
                try same(found, row[2], row)
            } else {
                #expect(row[2].isNull)
            }
        case "nearest_emergency":
            let found = CentreRules.nearestEmergency(
                state, lat: try #require(row[1].double), lng: try #require(row[2].double))
            try same(try #require(found), row[3], row)
        case "emergency_list":
            try same(
                CentreRules.emergencyList(state, origin: point(row[1], row[2])), row[3], row)
        case "rank":
            let entries = try #require(row[1].array).map(option)
            let ordered = CentreRules.rank(entries, locatedAt: point(row[2], row[3]))
            #expect(ordered.map(\.id) == row[4].array?.compactMap(\.string), "\(text(.array(row)))")
        case "suggest":
            let entries = try #require(row[1].array).map(option)
            let found = CentreRules.suggest(entries, reference: point(row[2], row[3]))
            if let found {
                try same(found, row[4], row)
            } else {
                #expect(row[4].isNull, "\(text(.array(row)))")
            }
        default:
            Issue.record("No case for \(text(row[0]))")
        }
    }

    @Test func `centres match case for case`() throws {
        let golden = try Golden.load(.clinic, "centres", as: Row.self)
        let clock = try TestClock(Self.noon)
        var engine = makeEngine(clock)
        var states: [ClinicState] = []
        for load in try #require(golden.header["loads"]?.array).compactMap(\.int) {
            var state = try ClinicState.fresh(engine: &engine, simulateLoad: true)
            for _ in 0..<load {
                _ = try engine.issueSimulated(&state, counterId: "C-WAKRA-T1")
            }
            states.append(state)
        }
        let shared = engine
        let ran = try golden.run { row in
            try centreRow(row, states: states, engine: shared)
        }
        #expect(ran == golden.count)
    }

    @Test func `distances match to the last bit`() throws {
        let golden = try Golden.load(.clinic, "geo", as: [Double].self)
        let ran = golden.run { row in
            let found = ClinicGeo.distanceM(row[0], row[1], row[2], row[3])
            #expect(found == row[4], "\(row)")
        }
        #expect(ran == golden.count)
    }

    @Test func `time functions match Python`() throws {
        let golden = try Golden.load(.clinic, "time", as: Row.self)
        let ran = try golden.run { row in
            let args = try #require(row[1].array).compactMap(\.string)
            switch row[0].string {
            case "doha_day":
                let date = try #require(ClinicTime.parse(args[0]))
                #expect(ClinicTime.dohaDay(date) == row[2].string, "\(args)")
            case "iso", "parse":
                let date = try #require(ClinicTime.parse(args[0]))
                #expect(ClinicTime.iso(date) == row[2].string, "\(args)")
            case "age_on":
                let found = args[1].contains("T")
                    ? ClinicTime.ageOn(dob: args[0], at: try #require(ClinicTime.parse(args[1])))
                    : ClinicTime.ageOn(dob: args[0], day: args[1])
                #expect(found == row[2].int, "\(args)")
            default:
                Issue.record("No case for \(text(row[0]))")
            }
        }
        #expect(ran == golden.count)
    }

    @Test func `the allergy rule matches Python`() throws {
        let golden = try Golden.load(.clinic, "allergy", as: Row.self)
        let ran = try golden.run { row in
            switch row[0].string {
            case "conflict":
                let allergies = row[1].object?["allergies"]?.array?.compactMap(\.string) ?? []
                let found = VisitFlow.allergyConflict(
                    allergies: allergies, drug: try goldenDrug(row[2]))
                let shaped: JSONValue = found.map {
                    .object([
                        "allergen": .string($0.allergen), "text_en": .string($0.textEn),
                        "text_ar": .string($0.textAr),
                    ])
                } ?? .null
                #expect(sameJSON(shaped, row[3]), "\(text(.array(row)))\nfound \(text(shaped))")
            case "default_items":
                var state = ClinicState()
                let forced = try #require(row[2].array).compactMap(\.string)
                for index in state.drugs.indices {
                    let id = state.drugs[index].id
                    let base = id == "DR-PARA" || id == "DR-DEXT"
                    state.drugs[index].demoDefault = base || forced.contains(id) ? 1 : 0
                }
                let patientId = try #require(row[1].string)
                let patient = try #require(state.patient(patientId))
                let items = try VisitFlow.defaultItems(state, allergies: patient.allergies)
                let shaped: [JSONValue] = items.map {
                    .object([
                        "drug_id": .string($0.drug.id), "dose": .optional($0.dose),
                        "frequency": .optional($0.frequency), "days": .optional($0.days),
                        "notes": .optional($0.notes),
                    ])
                }
                #expect(sameJSON(.array(shaped), row[3]), "\(text(.array(row)))")
            default:
                Issue.record("No case for \(text(row[0]))")
            }
        }
        #expect(ran == golden.count)
    }

    private func reference(_ text: String) throws -> AgeReference {
        text.contains("T") ? .instant(try #require(ClinicTime.parse(text))) : .day(text)
    }

    @Test func `the mock health record matches Python`() throws {
        let golden = try Golden.load(.clinic, "mock_health", as: Row.self)
        let clock = try #require(golden.header["clock"]?.string)
        let now = try #require(ClinicTime.parse(clock))
        let state = ClinicState()
        let ran = try golden.run { row in
            let args = try #require(row[1].array).compactMap(\.string)
            let expected = withoutNulls(row[2])
            let found: JSONValue?
            switch row[0].string {
            case "get_patient":
                found = try MockHealth.patient(state, id: args[0], on: reference(args[1]))
                    .map(plainJSON)
            case "get_dependents":
                found = try plainJSON(
                    MockHealth.dependents(state, guardianId: args[0], on: reference(args[1])))
            case "get_record":
                found = MockHealth.record(state, patientId: args[0])
            case "list_demo_patients":
                found = try plainJSON(MockHealth.demoPatients(state))
            case "find_by_qid":
                found = try MockHealth.findByQid(state, qid: args[0], now: now).map(plainJSON)
            default:
                found = nil
                Issue.record("No case for \(text(row[0]))")
            }
            #expect(sameJSON(found ?? .null, expected), "\(text(.array(row)))\nfound \(text(found ?? .null))")
        }
        #expect(ran == golden.count)
    }
}
