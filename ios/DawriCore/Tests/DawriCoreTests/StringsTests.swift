import Foundation
import Testing
@testable import DawriCore

@Suite struct TranslateTests {
    private let strings = Strings(
        en: ["hello": "Hello {name}, {count} left", "mark": "{age}\u{064B}", "plain": "Plain"],
        ar: ["hello": "مرحبا {name}"],
        recordTerms: ["penicillin": "البنسلين"])

    @Test func `a missing key comes back as the key`() {
        #expect(strings.translate(.en, "no.such.key") == "no.such.key")
        #expect(strings.translate(.ar, "plain") == "plain")
    }

    @Test func `placeholders are filled`() {
        #expect(strings.translate(.en, "hello", ["name": "Fatima", "count": 3])
            == "Hello Fatima, 3 left")
    }

    @Test func `an unknown placeholder stays as written`() {
        #expect(strings.translate(.en, "hello", ["name": "Fatima"]) == "Hello Fatima, {count} left")
    }

    @Test func `no vars leaves the text alone`() {
        #expect(strings.translate(.en, "hello") == "Hello {name}, {count} left")
    }

    @Test func `numbers stay in Latin digits in Arabic`() {
        #expect(strings.translate(.ar, "hello", ["name": 34]) == "مرحبا 34")
    }

    @Test func `a replacement holding braces is not filled again`() {
        #expect(strings.translate(.ar, "hello", ["name": "{name}"]) == "مرحبا {name}")
    }

    @Test func `an Arabic mark after a placeholder does not hide it`() {
        #expect(strings.translate(.en, "mark", ["age": 7]) == "7\u{064B}")
    }

    @Test func `real strings fill their placeholders`() {
        #expect(Strings.bundled.translate(.en, "who.age", ["age": 34]).contains("34"))
        #expect(Strings.bundled.translate(.ar, "who.age", ["age": 34]).contains("34"))
    }

    @Test func `directions`() {
        #expect(dirOf(.ar) == .rtl)
        #expect(dirOf(.en) == .ltr)
        #expect(Lang.ar.dir == .rtl)
    }

    @Test func `record terms in Arabic`() {
        let bundled = Strings.bundled
        #expect(bundled.recordTerm("penicillin", lang: .ar) == "البنسلين")
        #expect(bundled.recordTerm("  Penicillin ", lang: .ar) == "البنسلين")
        #expect(bundled.recordTerm("Type 2 Diabetes", lang: .ar) == "السكري من النوع الثاني")
    }

    @Test func `record terms stay as stored in English and when unknown`() {
        let bundled = Strings.bundled
        #expect(bundled.recordTerm("Penicillin", lang: .en) == "Penicillin")
        #expect(bundled.recordTerm("Sulfa drugs", lang: .ar) == "Sulfa drugs")
    }
}

@Suite struct FormatTests {
    @Test func `names follow the language`() throws {
        let patient = try Fixture.decode(AuthVerifyResponse.self, "auth_verify").patient
        #expect(nameOf(patient, lang: .ar) == "فاطمة التجريبية")
        #expect(nameOf(patient, lang: .en) == "Fatima Al-Demo")
        let demo = try #require(try Fixture.decode([DemoPatient].self, "demo_patients").first)
        #expect(nameOf(demo, lang: .ar) == "فاطمة التجريبية")
    }

    @Test func `centre names follow the language`() throws {
        let list = try Fixture.decode(CentreList.self, "centre_list")
        let option = try #require(list.centres.first)
        #expect(centreName(option, lang: .ar) == "مركز الوكرة الصحي")
        #expect(centreName(option, lang: .en) == "Al Wakra Health Centre")
        let ed = try #require(try Fixture.decode(ChatResponse.self, "chat_emergency").nearestEd)
        #expect(centreName(ed, lang: .en) == "Hamad General Hospital")
    }

    /// Each expected value is what the web's `formatDate` printed under Node's Intl. September
    /// in English is left out: Node's ICU data says "Sept" and Apple's says "Sep".
    @Test(arguments: [
        ("2026-11-07T09:00:00.000000+00:00", Lang.en, "7 Nov 2026"),
        ("2026-11-07T09:00:00.000000+00:00", Lang.ar, "7 نوفمبر 2026"),
        ("2026-11-07T22:30:00.000000+00:00", Lang.en, "8 Nov 2026"),
        ("2026-11-07T22:30:00.000000+00:00", Lang.ar, "8 نوفمبر 2026"),
        ("2026-01-31T20:59:59.000000+00:00", Lang.ar, "31 يناير 2026"),
        ("2026-05-03T21:00:00.000000+00:00", Lang.ar, "4 مايو 2026"),
        ("2026-05-03T21:00:00.000000+00:00", Lang.en, "4 May 2026"),
        ("2026-09-05T09:00:00.000000+00:00", Lang.ar, "5 سبتمبر 2026"),
    ])
    func `dates match the web`(iso: String, lang: Lang, text: String) {
        #expect(formatDate(iso, lang: lang) == text)
    }

    @Test func `something that is not a timestamp stays as stored`() {
        #expect(formatDate("not a date", lang: .en) == "not a date")
    }
}
