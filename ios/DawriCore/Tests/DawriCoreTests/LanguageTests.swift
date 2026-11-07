import Testing
@testable import DawriCore

/// The port of frontend/src/i18n/language.test.tsx. The checks on `html` become `dir`.
@Suite("Language rules") @MainActor
struct LanguageTests {
    @Test func `defaults to Arabic, right to left`() {
        let language = LanguageState(store: MemoryStore())
        #expect(language.lang == .ar)
        #expect(language.dir == .rtl)
        #expect(Strings.bundled.translate(language.lang, "home.start") == "بدء تسجيل الوصول")
    }

    @Test func `follows the record on login`() {
        let language = LanguageState(store: MemoryStore())
        language.applyPreferred("en")
        #expect(language.lang == .en)
        #expect(language.dir == .ltr)
    }

    @Test func `a record in any other language is Arabic`() {
        let language = LanguageState(store: MemoryStore(["dawri.lang": "en"]))
        language.applyPreferred("fr")
        #expect(language.lang == .ar)
    }

    @Test func `keeps a tapped choice over the record until logout`() {
        let language = LanguageState(store: MemoryStore())
        language.setLang(.en)
        language.applyPreferred("ar")
        #expect(language.lang == .en)
        language.reset()
        #expect(language.lang == .ar)
        language.applyPreferred("en")
        #expect(language.lang == .en)
    }

    @Test func `keeps a tapped choice across a restart`() {
        let store = MemoryStore()
        LanguageState(store: store).setLang(.en)
        let language = LanguageState(store: store)
        #expect(language.lang == .en)
        language.applyPreferred("ar")
        #expect(language.lang == .en)
    }

    @Test func `the record's language is remembered without counting as a choice`() {
        let store = MemoryStore()
        LanguageState(store: store).applyPreferred("en")
        #expect(store.values == ["dawri.lang": "en"])
        let language = LanguageState(store: store)
        #expect(language.lang == .en)
        language.applyPreferred("ar")
        #expect(language.lang == .ar)
    }

    @Test func `setLang writes both keys and reset clears both`() {
        let store = MemoryStore()
        let language = LanguageState(store: store)
        language.setLang(.en)
        #expect(store.values == ["dawri.lang": "en", "dawri.lang.chosen": "1"])
        language.reset()
        #expect(store.values.isEmpty)
    }

    @Test func `a stored value that is not a language is Arabic`() {
        #expect(LanguageState(store: MemoryStore(["dawri.lang": "fr"])).lang == .ar)
    }

    @Test func `works when the store refuses everything`() {
        let language = LanguageState(store: MemoryStore(blocked: true))
        language.setLang(.en)
        #expect(language.lang == .en)
    }
}
