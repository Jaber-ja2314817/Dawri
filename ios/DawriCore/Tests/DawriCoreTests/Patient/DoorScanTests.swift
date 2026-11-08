import Testing
@testable import DawriCore

@Suite("S09 door scan: only DOOR-<centre id> is read, nothing is opened")
struct DoorScanTests {
    @Test(arguments: [
        ("DOOR-C-WAKRA", "DOOR-C-WAKRA"),
        ("  DOOR-C-WAKRA\n", "DOOR-C-WAKRA"),
        ("door-c-wakra", "DOOR-C-WAKRA"),
        ("Door-C-Airport", "DOOR-C-AIRPORT"),
        ("DOOR-C-7", "DOOR-C-7"),
        ("DOOR-C-٧", "DOOR-C-7"),
        ("DOOR-C-۷", "DOOR-C-7"),
        ("DOOR-12", "DOOR-12"),
    ])
    func `a door code is accepted after trimming, upper-casing and Latin digits`(
        payload: String, code: String
    ) {
        #expect(DoorScan.code(fromPayload: payload) == code)
    }

    @Test func `the read code is the one a typed code would send`() {
        for payload in ["door-c-wakra", " DOOR-C-٧ "] {
            #expect(DoorScan.code(fromPayload: payload) == TicketRules.doorCode(payload))
        }
    }

    @Test(arguments: [
        "https://example.com",
        "http://DOOR-C-WAKRA",
        "https://example.com/DOOR-C-WAKRA",
        "DOOR-C-WAKRA?next=https://example.com",
        "dawri://DOOR-C-WAKRA",
        "tel:999",
        "mailto:a@b.c",
        "DOOR-C-WAKRA.example.com",
        "DOOR-C-WAKRA/",
    ])
    func `a link is never a door code`(payload: String) {
        #expect(DoorScan.code(fromPayload: payload) == nil)
    }

    @Test(arguments: [
        "", "   ", "DOOR", "DOOR-", "DOOR--C", "DOOR-C-", "DOOR-C--WAKRA", "C-WAKRA", "WAKRA",
        "XDOOR-C-WAKRA", "DOOR C-WAKRA", "DOOR-C WAKRA", "DOOR-C-WAKRA\nDOOR-C-RAYYAN",
        "DOOR_C_WAKRA", "DOOR-C-وكرة", "DOOR-C-ſ", "DOOR-C-WAKRA\u{00A0}",
        "DOOR-" + String(repeating: "A", count: 80),
    ])
    func `anything else is refused`(payload: String) {
        #expect(DoorScan.code(fromPayload: payload) == nil)
    }

    @Test func `the limit is on the payload, not the code`() {
        let longest = "DOOR-" + String(repeating: "A", count: DoorScan.maxLength - 5)
        #expect(DoorScan.code(fromPayload: longest) == longest)
        #expect(DoorScan.code(fromPayload: longest + "A") == nil)
    }
}
