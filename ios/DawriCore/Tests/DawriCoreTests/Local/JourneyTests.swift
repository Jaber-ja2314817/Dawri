import Foundation
import Testing
@testable import DawriCore

private let languages = ["ar", "en"]

extension Local {
    /// The three patients of HANDOFF.md at service level, in both languages.
    @Suite("Local: the three journeys")
    struct JourneyTests {
        @Test(arguments: languages)
        func `Fatima gets her numbers and medicines through the demo clinic`(language: String) async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.confirmedVisit(language: language)
            let reserved = try await rig.service.reserve(visitId: visit, centreId: "C-WAKRA")
            #expect(reserved.ticket.number == nil)
            #expect(reserved.ticket.peopleAhead == nil)

            let arrived = try await rig.service.arrive(visitId: visit, body: .button)
            #expect(arrived.ticket.number == "T-014")
            #expect(arrived.ticket.peopleAhead == 3)

            let plan = try await rig.service.demoPlan(visitId: visit)
            var stages: [VisitStage] = []
            var numbers: [String] = []
            var ahead: [Int] = []
            for _ in plan {
                rig.clock.advance(seconds: 15)
                let seen = try await rig.service.getVisit(visitId: visit)
                stages.append(seen.stage)
                if let number = seen.ticket?.number, numbers.last != number { numbers.append(number) }
                if seen.stage == .triage, let people = seen.ticket?.peopleAhead { ahead.append(people) }
            }
            #expect(numbers == ["T-014", "D-GP-023", "P-031"])
            #expect(ahead == [2, 1, 0, 0, 0])
            #expect(stages.last == .completed)
            #expect(Array(Set(stages)).count == 4)

            let done = try await rig.service.getVisit(visitId: visit)
            #expect(done.stage == .completed)
            #expect(done.goTo == nil)
            #expect(done.medicines.en.map(\.drug) == ["DR-DEXT", "DR-PARA"])
            let lines = language == "ar" ? done.medicines.ar : done.medicines.en
            let words = lines.map(\.line).joined(separator: " ")
            let expected = language == "ar"
                ? ["باراسيتامول", "ديكستروميثورفان"] : ["Paracetamol", "Dextromethorphan"]
            for word in expected { #expect(words.contains(word)) }
            #expect(!words.lowercased().contains("penicillin"))
            #expect(!words.lowercased().contains("amoxicillin"))
            #expect(try await rig.service.rateVisit(visitId: visit, stars: 5).rating == 5)
        }

        @Test(arguments: languages)
        func `Ahmed gets the refill route and can carry on as GP`(language: String) async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.ahmedQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            let reply = try await rig.service.sendChat(
                visitId: visit, text: try #require(Said.ahmed[language]))
            #expect(reply.refill != nil)
            #expect(reply.status == .deflectedRefill)
            #expect(try await rig.service.getVisit(visitId: visit).ticket == nil)
            #expect(try await rig.service.listVisits().map(\.active) == [false])

            let carried = try await rig.service.continueRefill(visitId: visit)
            #expect(carried.status == .intake)
            #expect(carried.service == .gp)
            let declined = await rig.service.events("refill.declined", visitId: visit)
            #expect(declined.count == 1)

            _ = try await rig.service.reserve(visitId: visit, centreId: "C-RAYYAN")
            let arrived = try await rig.service.arrive(visitId: visit, body: .qrCode("DOOR-C-RAYYAN"))
            #expect(arrived.ticket.number != nil)
            rig.clock.advance(seconds: 15 * 12)
            let done = try await rig.service.getVisit(visitId: visit)
            #expect(done.stage == .completed)
            #expect(done.service == .gp)
        }

        @Test(arguments: languages)
        func `Ravi gets 999, the nearest hospital and never a ticket`(language: String) async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.raviQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            let reply = try await rig.service.sendChat(
                visitId: visit, text: try #require(Said.ravi[language]))
            #expect(reply.emergency)
            #expect(reply.reply.contains("999"))
            #expect(reply.nearestEd != nil)
            #expect(reply.status == .redirectedEmergency)
            #expect(await rig.service.events("redflag.hit", visitId: visit).count >= 1)

            let seen = try await rig.service.getVisit(visitId: visit)
            #expect(seen.stage == .emergency)
            #expect(seen.ticket == nil)
            #expect(seen.emergency?.nearestEd == reply.nearestEd)
            #expect(seen.emergency?.replyEn?.contains("999") == true)
            #expect(seen.emergency?.replyAr?.contains("999") == true)

            let override = try await rig.service.emergencyOverride(visitId: visit)
            #expect(override.ticket == nil)
            #expect(await rig.service.events("emergency.override", visitId: visit).count == 1)
            #expect(try await rig.service.getVisit(visitId: visit).ticket == nil)

            await #expect {
                try await rig.service.createVisit(patientId: nil)
            } throws: { error in
                (error as? ClinicError)?.code == "emergency_today"
            }
            let tickets = await rig.service.testing { state, _ in
                state.clinic.tickets.filter { !$0.simulated }.count
            }
            #expect(tickets == 0)
        }
    }

    @Suite("Local: routes")
    struct RouteTests {
        private func long(_ head: String) -> String {
            String(repeating: "a ", count: 1100) + head
        }

        @Test func `consent is logged with who gave it`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.createVisit(patientId: "P004").visitId
            let row = try #require(await rig.service.events("consent.given", visitId: visit).first)
            #expect(row.payload == .object(["patient_id": .string("P004"), "booked_by": .string("P001")]))
            let refused = await #expect(throws: ClinicError.self) {
                try await rig.service.routeCreateVisit(consent: false, patientId: nil)
            }
            #expect(refused?.code == "consent_required")
        }

        @Test func `a patient in the waiting room still reaches the rules`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.arrivedVisit()
            let refused = await #expect(throws: ClinicError.self) {
                try await rig.service.sendChat(visitId: visit, text: "thanks")
            }
            #expect(refused?.code == "visit_not_in_intake")

            let reply = try await rig.service.sendChat(visitId: visit, text: long("chest pain"))
            #expect(reply.emergency)
            #expect(reply.status == .redirectedEmergency)
            let seen = try await rig.service.getVisit(visitId: visit)
            #expect(seen.stage == .emergency)
            #expect(seen.ticket == nil)
            let stored = try #require(seen.chat.messages.dropLast().last)
            #expect(stored.content.unicodeScalars.count == 2000)
        }

        @Test func `a red flag empties the patient's other queue places`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let held = try await rig.service.arrivedVisit()
            let reply = try await rig.service.sendChat(visitId: held, text: "chest pain")
            #expect(reply.emergency)
            let live = await rig.service.testing { state, engine in
                engine.liveTicketsOfPatient(state.clinic, patientId: "P001").count
            }
            #expect(live == 0)
            #expect(try await rig.service.getVisit(visitId: held).stage == .emergency)
        }

        @Test func `a 2,001 code point message ending in an astral character does not trap`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.createVisit(patientId: nil).visitId
            let text = String(repeating: "a", count: 2000) + "\u{1F600}"
            let refused = await #expect(throws: ClinicError.self) {
                try await rig.service.sendChat(visitId: visit, text: text)
            }
            #expect(refused?.code == "invalid_text")
            let reply = try await rig.service.sendChat(
                visitId: visit, text: "99999999999999999999 days")
            #expect(!reply.emergency)
        }

        @Test func `health is always simulated with the load on`() async throws {
            let rig = try LocalRig()
            let health = await rig.service.health()
            #expect(health == Health(status: "ok", aiMode: .simulated, simulateLoad: true))
        }

        @Test func `an unknown route input is a 422, and a bad location too`() async throws {
            let rig = try LocalRig()
            try await rig.signIn(Said.fatimaQid)
            let visit = try await rig.service.confirmedVisit()
            let badCentres = await #expect(throws: ClinicError.self) {
                try await rig.service.listCentres(service: "gp", visitId: visit, lat: 95, lng: 51)
            }
            #expect(badCentres?.code == "invalid_request")
            _ = try await rig.service.reserve(visitId: visit, centreId: "C-WAKRA")
            let badArrive = await #expect(throws: ClinicError.self) {
                try await rig.service.arrive(visitId: visit, body: .location(lat: .nan, lng: 51))
            }
            #expect(badArrive?.code == "invalid_request")
        }

        @Test func `the engine's words on the phone carry none of the banned claims`() throws {
            let root = "ios/DawriCore/Sources/DawriCore/Engine/Local"
            let names = try FileManager.default.contentsOfDirectory(
                atPath: Repo.root.appending(path: root).path)
            #expect(names.count >= 8)
            for name in names {
                let source = try Repo.text("\(root)/\(name)").lowercased()
                for banned in ["place held", "no-show", "clinically reviewed", "urlsession", "hf.space", "huggingface", "/api/asr"] {
                    #expect(!source.contains(banned), "\(name) says \(banned)")
                }
            }
        }
    }
}
