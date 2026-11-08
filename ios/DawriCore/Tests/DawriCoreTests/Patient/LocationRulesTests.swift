import Foundation
import Testing
@testable import DawriCore

@Suite("S08 and S09 location: one reading on a tap, when in use only")
struct LocationRulesTests {
    @Test func `the timeout is location.ts's 10 s, and the purpose key is ArrivalCheck`() {
        #expect(LocationRules.timeout == .seconds(10))
        #expect(LocationRules.fullAccuracyPurposeKey == "ArrivalCheck")
    }

    // Permission

    @Test func `not determined asks on this tap, once`() {
        #expect(LocationRules.permission(.notDetermined, asked: false) == .ask)
        #expect(LocationRules.permission(.notDetermined, asked: true) == .fail(.denied))
    }

    @Test(arguments: [LocationAuthorization.denied, .restricted])
    func `denied or restricted fails without asking`(status: LocationAuthorization) {
        #expect(LocationRules.permission(status, asked: false) == .fail(.denied))
        #expect(LocationRules.permission(status, asked: true) == .fail(.denied))
    }

    @Test(arguments: [LocationAuthorization.whenInUse, .always])
    func `when in use reads`(status: LocationAuthorization) {
        #expect(LocationRules.permission(status, asked: false) == .read)
        #expect(LocationRules.permission(status, asked: true) == .read)
    }

    @Test func `every status has an answer`() {
        for status in LocationAuthorization.allCases {
            for asked in [false, true] {
                _ = LocationRules.permission(status, asked: asked)
            }
        }
    }

    // Precision

    @Test func `full accuracy reads`() {
        #expect(LocationRules.precision(.full, asked: false) == .read)
        #expect(LocationRules.precision(.full, asked: true) == .read)
    }

    @Test func `reduced accuracy asks once for temporary full accuracy, then is imprecise`() {
        #expect(LocationRules.precision(.reduced, asked: false) == .askFullAccuracy)
        #expect(LocationRules.precision(.reduced, asked: true) == .fail(.imprecise))
    }

    // Readings

    @Test(arguments: [
        (0.0, 5.0), (29.9, 99.9), (30.0, 100.0), (-4.0, 0.0), (1.0, 65.0),
    ])
    func `a recent, sure reading is accepted`(age: Double, uncertainty: Double) {
        #expect(LocationRules.accepts(ageSeconds: age, uncertaintyMetres: uncertainty))
    }

    @Test(arguments: [
        (30.1, 5.0), (600.0, 5.0), (-6.0, 5.0),
        (0.0, 100.1), (0.0, 1414.0), (0.0, -1.0),
    ])
    func `a stale, unsure or invalid reading is refused`(age: Double, uncertainty: Double) {
        #expect(!LocationRules.accepts(ageSeconds: age, uncertaintyMetres: uncertainty))
    }

    @Test func `the uncertainty bound is inside the 150 m geofence`() {
        #expect(LocationRules.maxUncertaintyMetres < Double(TicketRules.geofenceMetres))
    }
}
