import Foundation
import Testing
@testable import DawriCore

private func person(age: Int, sex: String, lang: String, meds: [String] = [], allergies: [String] = []) -> Patient {
    Patient(
        id: "P", qidDemo: "DEMO", fullNameEn: "Demo", fullNameAr: "Demo", dob: "2000-01-01", age: age,
        sex: sex, preferredLang: lang, allergies: allergies, chronic: [], activeMeds: meds,
        registeredCentre: Centre(id: "C", nameEn: "C", nameAr: "C"), demo: true)
}

private let fatima = person(age: 34, sex: "F", lang: "ar", allergies: ["penicillin"])
private let ahmed = person(age: 67, sex: "M", lang: "ar", meds: ["amlodipine 5 mg once daily"])
private let ravi = person(age: 44, sex: "M", lang: "en", meds: ["metformin 500 mg twice daily"])

private func same(_ first: String?, _ second: String?) -> Bool {
    switch (first, second) {
    case (nil, nil): true
    case (let one?, let two?): sameScalars(one, two)
    default: false
    }
}

extension Rules {
    /// The expected values here were read from the Python, not written from the Swift.
    @Suite("Rules: the three demo patients")
    struct DemoSentenceTests {
        @Test func `Fatima stays in chat and is asked the severity`() throws {
            let text = "عندي حرارة وكحة من ثلاث أيام"
            let turn = try Receptionist.runTurn(text: text, history: [], patient: fatima, denied: [], lang: "ar")
            #expect(!turn.emergency)
            #expect(turn.refill == nil)
            #expect(!turn.done)
            #expect(same(turn.reply, "كم شدته من 0 إلى 10؟"))
            #expect(same(turn.slot, "severity"))
            #expect(same(turn.source, "simulated"))
            #expect(same(turn.language, "ar"))
            #expect(Scripted.findComplaints(text).elementsEqual(["fever", "cough"], by: sameScalars))
            #expect(same(Scripted.parseDuration(text), "3 days"))
        }

        @Test func `Fatima's whole chat reads back in Arabic with a valid intake`() throws {
            var history = [ChatMessage(role: .assistant, content: Scripted.opening(lang: "ar"), slot: "complaint")]
            var denied: [String] = []
            var last: TurnResult?
            for text in ["عندي حرارة وكحة من ثلاث أيام", "6", "لا", "اخذت بنادول"] {
                let turn = try Receptionist.runTurn(
                    text: text, history: history, patient: fatima, denied: denied, lang: "ar")
                history.append(ChatMessage(role: .user, content: text, slot: nil))
                history.append(
                    ChatMessage(role: .assistant, content: turn.reply, slot: turn.done ? Scripted.notAQuestion : turn.slot))
                denied = turn.denied
                last = turn
            }
            let turn = try #require(last)
            #expect(turn.done)
            #expect(same(turn.reply, "شكرا. هذا اللي بقوله للممرضة: حرارة وكحة، 3 أيام، الشدة 6 من 10، أخذت باراسيتامول. هل هذا صحيح؟"))
            let intake = try #require(turn.intake)
            #expect(same(intake.language, "ar-gulf"))
            #expect(same(intake.chiefComplaint, "fever and cough"))
            #expect(same(intake.chiefComplaintPatientWords, "عندي حرارة وكحة من ثلاث أيام"))
            #expect(same(intake.duration, "3 days"))
            #expect(intake.severity0To10 == 6)
            #expect(intake.associated.elementsEqual(["cough"], by: sameScalars))
            #expect(intake.selfMedication.elementsEqual(["paracetamol"], by: sameScalars))
            #expect(intake.service == .gp)
            #expect(intake.serviceConfidence == 0.85)
            #expect(same(intake.summaryForNurse, "34F, 3 days fever and cough, severity 6/10, took paracetamol."))
            #expect(intake.questionsAsked == 4)
            #expect(turn.events.map(\.type) == ["ai.turn", "ai.intake_ready"])

            let api = turn.toAPI(status: .intake)
            #expect(same(api.aiSource, "simulated"))
            #expect(api.intake?.severity0To10 == 6)
            #expect(api.intake?.refillRequest == nil)
        }

        @Test(arguments: [
            ("أبي حبوب الضغط المعتادة", "ar", "دواك المعتاد (amlodipine 5 mg once daily) ما يحتاج زيارة. راسل خط إعادة الصرف في مركزك."),
            ("I need my usual blood pressure pills", "en", "Your usual medicine (amlodipine 5 mg once daily) can be handled without a visit. Please message your centre's refill line."),
        ])
        func `Ahmed goes to the refill line with no ticket`(text: String, lang: String, reply: String) throws {
            let turn = try Receptionist.runTurn(text: text, history: [], patient: ahmed, denied: [], lang: lang)
            #expect(same(turn.refill?.medicine, "amlodipine 5 mg once daily"))
            #expect(same(turn.reply, reply))
            #expect(same(turn.source, "rules"))
            #expect(!turn.done)
            #expect(!turn.emergency)
            #expect(turn.intake == nil)
            #expect(same(Refill.detect(text, activeMeds: ahmed.activeMeds)?.medicine, "amlodipine 5 mg once daily"))
            #expect(turn.events.map(\.type) == ["refill.detected", "ai.turn"])
        }

        @Test func `I still want a visit continues as GP`() throws {
            let history = [
                ChatMessage(role: .assistant, content: Scripted.opening(lang: "ar"), slot: "complaint"),
                ChatMessage(role: .user, content: "أبي حبوب الضغط المعتادة", slot: nil),
            ]
            let intake = try Scripted.gpIntakeAfterRefill(
                history: history, patient: ahmed, medicine: "amlodipine 5 mg once daily",
                denied: ["chest pain"], lang: "ar")
            #expect(intake.service == .gp)
            #expect(same(intake.chiefComplaint, "amlodipine refill"))
            #expect(same(intake.refillRequest, "amlodipine 5 mg once daily"))
            #expect(same(intake.summaryForNurse, "67M, amlodipine refill, patient asked for a visit. Patient denied: chest pain."))
            #expect(same(intake.language, "ar-gulf"))
            #expect(intake.questionsAsked == 1)
        }

        @Test func `Ravi in English stops at the emergency reply with 999`() throws {
            let turn = try Receptionist.runTurn(
                text: "Chest pain spreading to my arm", history: [], patient: ravi, denied: [], lang: "en")
            #expect(turn.emergency)
            #expect(turn.intake == nil)
            #expect(turn.refill == nil)
            #expect(!turn.done)
            #expect(same(turn.emergencyCategory, "chest_pain"))
            #expect(same(turn.reply, "This needs urgent care. Please go to the nearest emergency department now, or call 999."))
            #expect(turn.fired.elementsEqual(["chest pain", "pain spreading to arm or jaw"], by: sameScalars))
            #expect(same(turn.source, "rules"))
        }

        @Test func `Ravi in Arabic stops at the emergency reply with 999`() throws {
            let turn = try Receptionist.runTurn(
                text: "ألم في الصدر ينتشر إلى ذراعي", history: [], patient: ravi, denied: [], lang: "ar")
            #expect(turn.emergency)
            #expect(turn.intake == nil)
            #expect(same(turn.reply, "هذا يحتاج رعاية عاجلة. توجه الآن إلى أقرب قسم طوارئ، أو اتصل على 999."))
            #expect(same(turn.language, "ar"))
            #expect(turn.fired.elementsEqual(["chest pain", "pain spreading to arm or jaw"], by: sameScalars))
            let hit = try #require(RedFlags.check("ألم في الصدر ينتشر إلى ذراعي").hits.first)
            #expect(same(hit.cue, "ألم في الصدر"))
        }

        @Test func `self-harm adds the supportive line`() throws {
            let turn = try Receptionist.runTurn(
                text: "I want to end my life", history: [], patient: ravi, denied: [], lang: "en")
            #expect(turn.emergency)
            #expect(turn.selfHarm)
            #expect(same(turn.emergencyCategory, "self_harm"))
            #expect(same(turn.reply, "This needs urgent care. Please go to the nearest emergency department now, or call 999. You are not alone. Please talk to someone right now, a person you trust or the team on 999."))
        }

        @Test func `rules alone report the same emergency and nothing else`() {
            #expect(Receptionist.ruleEmergency(text: "chest pain", history: [], patient: ravi)?.emergency == true)
            #expect(Receptionist.ruleEmergency(text: "I have a cough", history: [], patient: ravi) == nil)
        }
    }

    /// Where Python and Swift disagree about numbers and text. None of these may trap.
    @Suite("Rules: edges of the port")
    struct EdgeTests {
        @Test func `a number of any length reads as Python reads it`() {
            #expect(same(Scripted.parseDuration("99999999999999999999 days"), "99999999999999999999 days"))
            #expect(same(Scripted.parseDuration("007 days"), "7 days"))
            #expect(same(Scripted.parseDuration("٠٠٧ أيام"), "7 days"))
            #expect(same(Scripted.parseDuration("1 days"), "1 day"))
            #expect(Scripted.parseDuration("0 days") == nil)
            #expect(Scripted.parseSeverity("99999999999999999999/10") == nil)
            #expect(Scripted.parseSeverity("10/10") == 10)
            #expect(Scripted.parseSeverity("11/10") == nil)
            #expect(Scripted.parseSeverity("٣/١٠") == 3)
            #expect(Scripted.parseSeverity("007 days", loose: true) == 7)
        }

        @Test func `a digit-like character int() refuses is no number`() throws {
            #expect(Scripted.parseDuration("፩ days") == nil)
            #expect(Scripted.parseSeverity("፩") == nil)
            #expect(Scripted.parseSeverity("፩/10", loose: true) == 10)
            let history = [
                ChatMessage(role: .assistant, content: "What brings you in today?", slot: "complaint"),
                ChatMessage(role: .user, content: "fever for 3 days", slot: nil),
                ChatMessage(role: .assistant, content: "Thanks.", slot: Scripted.notAQuestion),
            ]
            // Python raises here, on int('፩'). This is the one permitted difference.
            _ = try Receptionist.runTurn(text: "፩", history: history, patient: ravi, denied: [], lang: "en")
        }

        @Test func `the read-back counts a long number without trapping`() {
            let facts = ReadBackFacts(
                chiefComplaint: "fever", chiefComplaintPatientWords: "x",
                duration: "99999999999999999999 days", severity0To10: nil, selfMedication: [],
                deniedRedFlags: [])
            #expect(same(Scripted.summaryReply(facts, lang: "ar"), "شكرا. هذا اللي بقوله للممرضة: حرارة، 99999999999999999999 أيام. هل هذا صحيح؟"))
        }

        @Test func `a long message ending in an astral character is cut by code points`() throws {
            let text = String(repeating: "a", count: 2000) + "\u{1F600}"
            #expect(text.unicodeScalars.count == 2001)
            #expect(RedFlags.check(text).hits.isEmpty)
            #expect(TextRules.normalise(text).count == 2001)
            #expect(TextRules.splitSentences(text.scalars).count == 1)
            let emoji = String(repeating: "\u{1F600}", count: 1001)
            let turn = try Receptionist.runTurn(
                text: emoji,
                history: (0..<6).flatMap { _ in
                    [
                        ChatMessage(role: .assistant, content: "Since when?", slot: "duration"),
                        ChatMessage(role: .user, content: emoji, slot: nil),
                    ]
                },
                patient: ravi, denied: [], lang: "en")
            let intake = try #require(turn.intake)
            #expect(intake.chiefComplaintPatientWords.unicodeScalars.count == 1000)
            #expect(intake.chiefComplaint.unicodeScalars.count == 200)
        }

        @Test func `text keeps the scalars it was given`() {
            // NFKC composes this one, and a mark with no composition splits a word, as \w does.
            #expect(TextRules.tokenise("e\u{301}").map(\.text) == [[0xE9]])
            #expect(TextRules.tokenise("a\u{0610}b").map(\.text) == [[0x61], [0x62]])
            #expect(TextRules.normalise("a\r\nb") == "a\nb".scalars)
            #expect(TextRules.normalise("a\u{2028}b") == "a\nb".scalars)
            #expect(Refill.detect("\u{0}", activeMeds: []) == nil)
        }

        @Test func `add_denied keeps the line and trims the summary`() {
            let summary = String(repeating: "x", count: 395)
            let line = Scripted.addDenied(summary, denied: ["chest pain"])
            #expect(line.unicodeScalars.count == 400)
            #expect(line.hasSuffix(" Patient denied: chest pain."))
            #expect(same(Scripted.addDenied("x   ", denied: ["chest pain"]), "x Patient denied: chest pain."))
            #expect(same(Scripted.addDenied("Patient denied: chest pain", denied: ["chest pain"]), "Patient denied: chest pain"))
            #expect(same(Scripted.addDenied("fine", denied: []), "fine"))
            let astral = Scripted.addDenied(String(repeating: "\u{1F600}", count: 395), denied: ["chest pain"])
            #expect(astral.unicodeScalars.count == 400)
        }

        @Test func `every phrase has a first word, so the first word index misses nothing`() {
            let tables = RuleTables.shared
            let lists: [PhraseList] =
                [
                    tables.redFlags.cueList, tables.redFlags.sideList, tables.redFlags.notHere,
                    tables.redFlags.noAnswers, tables.refill.intents, tables.refill.nouns,
                    tables.refill.symptoms, tables.refill.cancels, tables.refill.usuals,
                    tables.refill.requests, tables.filters.diseaseTerms, tables.filters.conditionTriggers,
                    tables.filters.allDrugPhrases, tables.filters.queueTerms,
                ] + tables.simulated.complaints.map(\.phrases) + tables.simulated.medicines.map(\.phrases)
            for list in lists {
                #expect(list.phrases.allSatisfy { !$0.isEmpty })
            }
        }

        @Test func `the first word index finds what a full scan finds`() {
            let tokens = TextRules.tokenise("no chest pain but والألم في الصدر and chest pain again")
            let list = RuleTables.shared.redFlags.cueList
            let scanned = list.phrases.indices.flatMap { phrase in
                TextRules.phraseStarts(tokens, list.phrases[phrase]).map { [phrase, $0] }
            }
            #expect(list.matches(in: tokens).map { [$0.phrase, $0.start] } == scanned)
        }
    }

    @Suite("Rules: the intake schema")
    struct IntakeSchemaTests {
        private func draft(
            language: String = "en", complaint: String = "a", words: String = "b", service: String = "gp",
            summary: String = "c", severity: Int? = nil, questions: Int = 1
        ) -> IntakeDraft {
            IntakeDraft(
                language: language, chiefComplaint: complaint, chiefComplaintPatientWords: words,
                severity0To10: severity, service: service, serviceConfidence: 0.5, summaryForNurse: summary,
                questionsAsked: questions)
        }

        @Test func `strips as pydantic does`() throws {
            let record = try IntakeRecord.validate(
                draft(complaint: "  a  ", words: " b ", summary: " c\u{85}", questions: 6))
            #expect(same(record.chiefComplaint, "a"))
            #expect(same(record.chiefComplaintPatientWords, "b"))
            #expect(same(record.summaryForNurse, "c"))
            // U+001C is space to str.strip and not to pydantic.
            #expect(same(try IntakeRecord.validate(draft(complaint: "a\u{1C}")).chiefComplaint, "a\u{1C}"))
        }

        @Test func `lengths count code points`() throws {
            _ = try IntakeRecord.validate(draft(complaint: String(repeating: "\u{1F600}", count: 200)))
            #expect(throws: IntakeParseError.self) {
                try IntakeRecord.validate(draft(complaint: String(repeating: "a", count: 201)))
            }
        }

        @Test func `refuses what the schema refuses`() {
            let bad = [
                draft(complaint: "   "), draft(language: "fr"), draft(questions: 7), draft(questions: -1),
                draft(severity: 11), draft(severity: -1), draft(service: "flu"), draft(words: ""),
                draft(summary: ""),
            ]
            for item in bad {
                #expect(throws: IntakeParseError.self) { try IntakeRecord.validate(item) }
            }
        }

        @Test func `the patient view leaves the staff-only text out`() throws {
            var record = try IntakeRecord.validate(draft(summary: "secret"))
            record.refillRequest = "amlodipine"
            let data = try JSONEncoder().encode(record.patientView)
            let text = try #require(String(data: data, encoding: .utf8))
            #expect(!text.contains("secret"))
            #expect(!text.contains("summary_for_nurse"))
            #expect(!text.contains("chief_complaint\""))
            #expect(record.patientView.refillRequest == .medicine("amlodipine"))
        }

        @Test func `the record survives a round trip as JSON`() throws {
            let record = try IntakeRecord.validate(draft(severity: 4))
            let copy = try JSONDecoder().decode(IntakeRecord.self, from: JSONEncoder().encode(record))
            #expect(copy == record)
        }
    }
}
