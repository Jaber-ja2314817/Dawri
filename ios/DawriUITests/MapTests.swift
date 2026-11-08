import XCTest

/// S08's MapKit map, on the clinic on this phone: a badge per centre, a tap that selects and
/// leaves the camera alone, a map that stays left to right in Arabic, the list when there is no
/// network, and the list first at accessibility sizes.
final class MapTests: XCTestCase {
    private let centreIds = ["C-WAKRA", "C-RAYYAN", "C-MESAIMEER", "C-AIRPORT", "C-WESTBAY"]
    private let names: [String: (en: String, ar: String)] = [
        "C-WAKRA": ("Al Wakra Health Centre", "مركز الوكرة الصحي"),
        "C-AIRPORT": ("Airport Health Centre", "مركز المطار الصحي"),
    ]
    private let listLabel = ["en": "List", "ar": "القائمة"]
    private let mapLabel = ["en": "Map", "ar": "الخريطة"]

    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    private func openMap(_ lang: String, _ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-demoLang", lang, "-demoPatient", "DEMO-10001", "-demoScreen", "s08", "-demoFreeze", "1",
        ] + extra
        app.launch()
        assertShown(app.element("screen-centre"), lang)
        return app
    }

    @MainActor
    private func pin(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons["centre-pin-\(id)"].firstMatch
    }

    @MainActor
    private func showList(_ app: XCUIApplication, _ lang: String) {
        let segment = app.element("centre-view").buttons[listLabel[lang] ?? ""].firstMatch
        assertShown(segment, lang)
        segment.tap()
        assertShown(app.element("centre-list"), lang)
    }

    /// The selected card's heading. On the map view the list is hidden and the pins' names sit
    /// inside their labels, so the card holds the only text that is the name alone.
    @MainActor
    private func cardShows(_ name: String, in app: XCUIApplication) -> Bool {
        app.staticTexts[name].exists
    }

    /// The chosen list row, the one with the selected trait.
    @MainActor
    private func chosenRows(_ app: XCUIApplication) -> [XCUIElement] {
        app.buttons.matching(identifier: "centre-row").allElementsBoundByIndex.filter(\.isSelected)
    }

    @MainActor
    private func waitUntil(_ condition: () -> Bool, timeout: TimeInterval = 5) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

    // Pins

    /// One badge per centre in the list, and no others.
    @MainActor
    func testEveryListedCentreHasAPin() {
        let app = openMap("en")
        assertShown(app.element("centre-map"))
        for id in centreIds {
            assertShown(pin(id, in: app), id)
            // 44 pt, read back through the map's scale as 43.99999.
            XCTAssertGreaterThanOrEqual(pin(id, in: app).frame.width, 43.9, "\(id) is a 44 pt target")
            XCTAssertGreaterThanOrEqual(pin(id, in: app).frame.height, 43.9, "\(id) is a 44 pt target")
        }
        let pins = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'centre-pin-'")).count
        XCTAssertEqual(pins, centreIds.count)

        showList(app, "en")
        XCTAssertEqual(app.buttons.matching(identifier: "centre-row").count, pins)
    }

    /// The registered centre is selected on arrival, and its pin says so.
    @MainActor
    func testTheRegisteredCentreIsSelectedOnArrival() {
        let app = openMap("en")
        assertShown(pin("C-WAKRA", in: app))
        XCTAssertTrue(pin("C-WAKRA", in: app).isSelected)
        XCTAssertFalse(pin("C-AIRPORT", in: app).isSelected)
        XCTAssertTrue(cardShows("Al Wakra Health Centre", in: app))
        XCTAssertFalse(app.staticTexts["Airport Health Centre"].exists)
    }

    // Selection

    /// A tap on another pin moves the selection, and the card, the pins and the list's check mark
    /// all agree, in both languages.
    @MainActor
    func testTappingAPinSelectsItAndTheCardAndListAgree() {
        for lang in ["en", "ar"] {
            let app = openMap(lang)
            let airport = pin("C-AIRPORT", in: app)
            assertShown(airport, lang)
            XCTAssertFalse(airport.isSelected, lang)
            airport.tap()

            let name = lang == "en" ? names["C-AIRPORT"]!.en : names["C-AIRPORT"]!.ar
            XCTAssertTrue(
                waitUntil { self.cardShows(name, in: app) },
                "The card shows the tapped centre. \(lang)")
            XCTAssertTrue(waitUntil { airport.isSelected }, lang)
            XCTAssertFalse(pin("C-WAKRA", in: app).isSelected, "Only one pin is selected. \(lang)")
            let wakra = lang == "en" ? names["C-WAKRA"]!.en : names["C-WAKRA"]!.ar
            XCTAssertFalse(app.staticTexts[wakra].exists, "The card left Al Wakra. \(lang)")

            showList(app, lang)
            let chosen = chosenRows(app)
            XCTAssertEqual(chosen.count, 1, lang)
            XCTAssertTrue(chosen.first?.label.contains(name) ?? false, "\(chosen.first?.label ?? "none") \(lang)")

            // And back on the map, the pin still holds it.
            app.element("centre-view").buttons[mapLabel[lang] ?? ""].firstMatch.tap()
            assertShown(pin("C-AIRPORT", in: app), lang)
            XCTAssertTrue(pin("C-AIRPORT", in: app).isSelected, lang)
            app.terminate()
        }
    }

    /// The map stays put: a pin nobody touched is where it was after another is tapped.
    @MainActor
    func testTheCameraDoesNotMoveOnAPinTap() {
        let app = openMap("en")
        let wakra = pin("C-WAKRA", in: app)
        let westBay = pin("C-WESTBAY", in: app)
        assertShown(wakra)
        assertShown(westBay)
        // Let the fitted camera land before reading the frames.
        sleep(2)
        let before = (wakra.frame, westBay.frame)

        pin("C-AIRPORT", in: app).tap()
        XCTAssertTrue(waitUntil { self.pin("C-AIRPORT", in: app).isSelected })
        sleep(2)

        for (now, was, id) in [(wakra.frame, before.0, "C-WAKRA"), (westBay.frame, before.1, "C-WESTBAY")] {
            XCTAssertEqual(now.midX, was.midX, accuracy: 0.5, "\(id) moved: \(was) to \(now)")
            XCTAssertEqual(now.midY, was.midY, accuracy: 0.5, "\(id) moved: \(was) to \(now)")
        }
    }

    /// East stays right in Arabic: Al Wakra (51.596 E) is to the right of Al Rayyan (51.432 E) in
    /// both languages.
    @MainActor
    func testTheMapStaysLeftToRightInArabic() {
        for lang in ["en", "ar"] {
            let app = openMap(lang)
            let wakra = pin("C-WAKRA", in: app)
            let rayyan = pin("C-RAYYAN", in: app)
            assertShown(wakra, lang)
            assertShown(rayyan, lang)
            XCTAssertGreaterThan(
                wakra.frame.midX, rayyan.frame.midX, "Wakra \(wakra.frame), Rayyan \(rayyan.frame). \(lang)")
            app.terminate()
        }
    }

    /// VoiceOver reads each pin as `centre.pinLabel` in the app's language.
    @MainActor
    func testPinLabelsAreInTheCurrentLanguage() {
        for (lang, prefix, unit) in [
            ("en", "Al Wakra Health Centre, wait ", " min"), ("ar", "مركز الوكرة الصحي، الانتظار ", " د"),
        ] {
            let app = openMap(lang)
            let wakra = pin("C-WAKRA", in: app)
            assertShown(wakra, lang)
            XCTAssertTrue(wakra.label.hasPrefix(prefix), "'\(wakra.label)' \(lang)")
            XCTAssertTrue(wakra.label.hasSuffix(unit), "'\(wakra.label)' \(lang)")
            let figure = wakra.label.dropFirst(prefix.count).dropLast(unit.count)
            XCTAssertNotNil(Int(figure), "The wait is a Latin figure: '\(figure)' \(lang)")
            app.terminate()
        }
    }

    // When there is no map

    /// No network path at entry: the notice, the list only, and no picker.
    @MainActor
    func testOfflineShowsTheListOnlyWithTheNotice() {
        for (lang, notice) in [
            ("en", "The map could not load, so centres are shown as a list."),
            ("ar", "تعذر تحميل الخريطة، لذا تظهر المراكز في قائمة."),
        ] {
            let app = openMap(lang, ["-demoOffline", "1"])
            assertShown(app.element("map-failed"), lang)
            XCTAssertTrue(app.staticTexts[notice].exists, lang)
            assertShown(app.element("centre-list"), lang)
            XCTAssertFalse(app.element("centre-map").exists, lang)
            XCTAssertFalse(app.element("centre-view").exists, "No picker. \(lang)")
            XCTAssertEqual(
                app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'centre-pin-'")).count, 0, lang)
            // The list still checks in.
            assertShown(app.element("check-in-here"), lang)
            app.terminate()
        }
    }

    /// At AX3, S08 starts on the list, and the map is still there to choose, at 220 pt or more.
    @MainActor
    func testAccessibilitySizesStartOnTheList() {
        let app = openMap(
            "en", ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        assertShown(app.element("centre-list"))
        XCTAssertFalse(app.element("centre-map").exists)

        let segment = app.element("centre-view").buttons["Map"].firstMatch
        assertShown(segment)
        segment.tap()
        let map = app.element("centre-map")
        assertShown(map)
        XCTAssertGreaterThanOrEqual(map.frame.height, 220)
        XCTAssertFalse(app.element("centre-list").exists)
    }
}
