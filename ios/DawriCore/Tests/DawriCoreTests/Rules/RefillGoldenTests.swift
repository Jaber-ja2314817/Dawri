import Foundation
import Testing
@testable import DawriCore

private struct RefillCase: Decodable {
    let text: String
    let activeMeds: Int
    let medicine: String?
    let cue: String?
    let blocks: Bool

    init(from decoder: any Decoder) throws {
        var row = try decoder.unkeyedContainer()
        _ = try row.decode(Int.self)
        text = try row.decode(String.self)
        activeMeds = try row.decode(Int.self)
        medicine = try row.decode(String?.self)
        cue = try row.decode(String?.self)
        blocks = try row.decode(Int.self) == 1
    }
}

extension Rules {
    @Suite("Rules: refill golden")
    struct RefillGoldenTests {
        @Test func `refill golden`() throws {
            let golden = try Golden.load(.rules, "refill", as: RefillCase.self)
            guard case .array(let lists)? = golden.header["active_meds"] else {
                Issue.record("refill.json has no active_meds header")
                return
            }
            let medicines = lists.map(rulesStrings)
            var differences = Differences("refill.json")
            let ran = golden.run { item in
                let match = Refill.detect(item.text, activeMeds: medicines[item.activeMeds])
                differences.check(item.text, "medicine", item.medicine, match?.medicine)
                differences.check(item.text, "cue", item.cue, match?.cue)
                differences.check(item.text, "blocks_refill", item.blocks, Refill.blocksRefill(item.text))
            }
            differences.finish(ran: ran)
            #expect(ran == golden.count)
        }
    }
}
