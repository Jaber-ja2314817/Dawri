import Foundation
import Testing
@testable import DawriCore

/// `NOW` in Home.test.tsx.
private let now = ClinicTime.parse("2026-11-06T09:00:00.000Z")!

/// `row()` in Home.test.tsx: V1 for P1, created now unless a stamp is given.
private func row(
    _ status: VisitStatus, createdAt: String = "2026-11-06T09:00:00.000Z", active: Bool = false,
    id: String = "V1"
) -> VisitRow {
    VisitRow(
        visitId: id, patientId: "P1", status: status, stage: status.stage, service: nil,
        centreId: nil, centre: nil, createdAt: createdAt, completedAt: nil, active: active)
}

@Suite("S03 and an emergency, every non-DOM case of Home.test.tsx")
struct HomeTestPortTests {
    @Test func `leads today's emergency to its visit, which goes on to S06`() {
        let emergency = row(.redirectedEmergency)
        #expect(VisitRules.openVisits([emergency], now: now) == [emergency])
        #expect(VisitRules.openAction(emergency) == .emergency(visitId: "V1"))
        #expect(Strings.bundled.translate(.en, "status.\(emergency.status.rawValue)") == "Sent to emergency")
        #expect(VisitRules.homeTone(emergency.status) == .negative)
    }

    @Test func `counts the day in Doha: 22:00 UTC yesterday is already today there`() {
        let late = row(.redirectedEmergency, createdAt: "2026-11-05T22:00:00.000Z")
        #expect(VisitRules.isOpen(late, now: now))
    }

    @Test func `does not keep an older emergency open for ever`() {
        let old = row(.redirectedEmergency, createdAt: "2026-11-04T09:00:00.000Z")
        #expect(!VisitRules.isOpen(old, now: now))
        #expect(VisitRules.openVisits([old], now: now).isEmpty)
    }

    @Test func `still leaves finished visits off the list`() {
        let rows = [row(.completed), row(.deflectedRefill), row(.cancelled)]
        #expect(VisitRules.openVisits(rows, now: now).isEmpty)
    }
}

@Suite("isEmergencyToday and isOpen")
struct OpenVisitTests {
    @Test func `Doha's midnight is the edge, 21:00 UTC`() {
        let before = row(.redirectedEmergency, createdAt: "2026-11-05T20:59:59.999999Z")
        let after = row(.redirectedEmergency, createdAt: "2026-11-05T21:00:00.000000Z")
        #expect(!VisitRules.isEmergencyToday(before, now: now))
        #expect(VisitRules.isEmergencyToday(after, now: now))
    }

    @Test func `today ends at Doha's next midnight too`() {
        let lateNow = ClinicTime.parse("2026-11-06T20:59:59Z")!
        let nextDay = ClinicTime.parse("2026-11-06T21:00:00Z")!
        let morning = row(.redirectedEmergency, createdAt: "2026-11-06T03:00:00Z")
        #expect(VisitRules.isEmergencyToday(morning, now: lateNow))
        #expect(!VisitRules.isEmergencyToday(morning, now: nextDay))
    }

    @Test func `a stamp with an offset is read as the instant it names`() {
        let offset = row(.redirectedEmergency, createdAt: "2026-11-06T00:30:00+03:00")
        #expect(VisitRules.isEmergencyToday(offset, now: now))
        let yesterday = row(.redirectedEmergency, createdAt: "2026-11-05T23:30:00+03:00")
        #expect(!VisitRules.isEmergencyToday(yesterday, now: now))
    }

    @Test func `a stamp that cannot be read is not today`() {
        #expect(!VisitRules.isEmergencyToday(row(.redirectedEmergency, createdAt: "yesterday"), now: now))
        #expect(!VisitRules.isEmergencyToday(row(.redirectedEmergency, createdAt: ""), now: now))
    }

    @Test(arguments: VisitStatus.allCases.filter { $0 != .redirectedEmergency })
    func `only an emergency can be an emergency today`(status: VisitStatus) {
        #expect(!VisitRules.isEmergencyToday(row(status), now: now))
    }

    @Test func `intake and expired are open whatever the active flag says`() {
        #expect(VisitRules.isOpen(row(.intake), now: now))
        #expect(VisitRules.isOpen(row(.expired), now: now))
    }

    @Test(arguments: [VisitStatus.reserved, .inTriage, .inDoctor, .inPharmacy])
    func `a live visit is open because the clinic marks it active`(status: VisitStatus) {
        #expect(VisitRules.isOpen(row(status, active: true), now: now))
        #expect(!VisitRules.isOpen(row(status, active: false), now: now))
    }

    @Test(arguments: [VisitStatus.completed, .deflectedRefill, .cancelled])
    func `a finished visit is never open`(status: VisitStatus) {
        #expect(!VisitRules.isOpen(row(status), now: now))
    }

    @Test func `the open list keeps the clinic's order`() {
        let rows = [
            row(.completed, id: "A"), row(.expired, id: "B"), row(.inTriage, active: true, id: "C"),
            row(.cancelled, id: "D"), row(.intake, id: "E"),
        ]
        #expect(VisitRules.openVisits(rows, now: now).map(\.visitId) == ["B", "C", "E"])
    }
}

@Suite("Status tones on S03 and S12")
struct ToneTests {
    @Test(arguments: VisitStatus.allCases)
    func `Home: emergency negative, expired warning, the rest neutral`(status: VisitStatus) {
        let expected: StatusTone =
            switch status {
            case .redirectedEmergency: .negative
            case .expired: .warning
            default: .neutral
            }
        #expect(VisitRules.homeTone(status) == expected)
    }

    @Test(arguments: VisitStatus.allCases)
    func `History: completed positive, emergency negative, expired warning, the rest neutral`(
        status: VisitStatus
    ) {
        let expected: StatusTone =
            switch status {
            case .completed: .positive
            case .redirectedEmergency: .negative
            case .expired: .warning
            default: .neutral
            }
        #expect(VisitRules.historyTone(status) == expected)
    }
}

@Suite("Which rows open, and to where")
struct RowRouteTests {
    @Test func `a completed row opens S11`() {
        #expect(VisitRules.historyRoute(row(.completed)) == .visit(id: "V1", screen: .complete))
    }

    @Test(arguments: [VisitStatus.redirectedEmergency, .deflectedRefill, .expired, .cancelled])
    func `NOT_LINKS rows do not open`(status: VisitStatus) {
        #expect(VisitRules.historyRoute(row(status)) == nil)
    }

    @Test(arguments: [VisitStatus.intake, .reserved, .inTriage, .inDoctor, .inPharmacy])
    func `a visit still going opens the visit, which finds its own screen`(status: VisitStatus) {
        #expect(VisitRules.historyRoute(row(status)) == .visitRoot(id: "V1"))
    }

    @Test func `every status is decided`() {
        let opening = VisitStatus.allCases.filter { VisitRules.historyRoute(row($0)) != nil }
        #expect(opening.count + VisitRules.historyDeadEnds.count == VisitStatus.allCases.count)
    }

    @Test(arguments: VisitStatus.allCases)
    func `on Home only an emergency row skips the gate, straight to S06`(status: VisitStatus) {
        let action = VisitRules.openAction(row(status))
        if status == .redirectedEmergency {
            #expect(action == .emergency(visitId: "V1"))
        } else {
            #expect(action == .visit(visitId: "V1"))
        }
    }
}

@Suite("The S12 detail line and the flagged allergy")
struct DetailAndAllergyTests {
    @Test func `the parts that exist, joined with a middle dot`() {
        #expect(VisitRules.detailLine(["6 Nov 2026", "General practice", "Layla Al-Demo"])
            == "6 Nov 2026 · General practice · Layla Al-Demo")
        #expect(VisitRules.detailLine(["6 Nov 2026", nil, "Layla Al-Demo"]) == "6 Nov 2026 · Layla Al-Demo")
        #expect(VisitRules.detailLine(["6 Nov 2026", nil, nil]) == "6 Nov 2026")
        #expect(VisitRules.detailLine(["6 Nov 2026", "", nil]) == "6 Nov 2026")
        #expect(VisitRules.detailLine([nil, nil]) == "")
    }

    @Test func `the date is the one formatDate gives, in both languages`() {
        let stamp = "2026-11-05T22:00:00.000000+00:00"
        let en = VisitRules.detailLine([formatDate(stamp, lang: .en), "General practice"])
        #expect(en == "6 Nov 2026 · General practice")
        let ar = VisitRules.detailLine([formatDate(stamp, lang: .ar), nil])
        #expect(ar.hasPrefix("6 "))
        #expect(ar.hasSuffix(" 2026"))
    }

    @Test func `penicillin is flagged, in any case`() {
        #expect(VisitRules.flaggedAllergy == "penicillin")
        #expect(VisitRules.isFlaggedAllergy("penicillin"))
        #expect(VisitRules.isFlaggedAllergy("Penicillin"))
        #expect(VisitRules.isFlaggedAllergy("PENICILLIN "))
    }

    @Test func `other allergies stay neutral`() {
        #expect(!VisitRules.isFlaggedAllergy("peanuts"))
        #expect(!VisitRules.isFlaggedAllergy("penicillins and cephalosporins"))
        #expect(!VisitRules.isFlaggedAllergy(""))
    }

    @Test func `Fatima's seeded allergy is the flagged one`() throws {
        let fatima = try #require(ClinicData.bundled.tables.patients.first { $0.id == "P001" })
        #expect(fatima.allergies.contains(where: VisitRules.isFlaggedAllergy))
    }
}
