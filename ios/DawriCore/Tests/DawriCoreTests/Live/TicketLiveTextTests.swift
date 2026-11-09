import Foundation
import SwiftUI
import Testing
@testable import DawriCore

@Suite("Live: TicketLiveText and colours")
struct TicketLiveTextTests {
    private func state(_ visit: Visit, _ lang: Lang = .en) -> TicketLiveState {
        LiveTicketRules.state(for: visit, lang: lang)
    }

    @Test func `the number is isolated left to right, and the minimal shows its last three digits`() throws {
        let active = state(try liveVisit())
        #expect(TicketLiveText.number(active) == "\u{2066}T-014\u{2069}")
        #expect(TicketLiveText.minimalNumber(active) == "\u{2066}014\u{2069}")
        #expect(TicketLiveText.number(state(try liveVisit(ticket: nil))) == nil)
    }

    @Test func `the wait has an isolated figure and the unit of the language`() throws {
        let visit = try liveVisit()
        #expect(TicketLiveText.strip(TicketLiveText.wait(state(visit), lang: .en)) == "12 min")
        #expect(TicketLiveText.strip(TicketLiveText.wait(state(visit, .ar), lang: .ar)) == "12 د")
        var zero = state(visit)
        zero.estWaitMin = 0
        #expect(TicketLiveText.strip(TicketLiveText.wait(zero, lang: .en)) == "0 min")
        zero.estWaitMin = nil
        #expect(TicketLiveText.wait(zero, lang: .en) == "–")
    }

    @Test func `compact trailing is the wait, go now, or the stage`() throws {
        #expect(TicketLiveText.strip(TicketLiveText.compactTrailing(state(try liveVisit()), lang: .en)) == "12 min")
        #expect(TicketLiveText.compactTrailing(state(try liveVisit(ticket: .called)), lang: .en) == "Go now")
        #expect(TicketLiveText.compactTrailing(state(try liveVisit(ticket: .called), .ar), lang: .ar) == "توجه الآن")
        #expect(TicketLiveText.compactTrailing(state(try liveVisit(ticket: .serving)), lang: .en) == "Triage")
        #expect(TicketLiveText.compactTrailing(state(try liveVisit(ticket: nil)), lang: .en) == "–")
    }

    @Test func `ahead and go now fill their placeholders`() throws {
        #expect(TicketLiveText.strip(TicketLiveText.ahead(state(try liveVisit()), lang: .en)) == "3 ahead")
        #expect(TicketLiveText.strip(TicketLiveText.ahead(state(try liveVisit(), .ar), lang: .ar)) == "3 أمامك")
        let called = state(try liveVisit(ticket: .called))
        #expect(TicketLiveText.strip(TicketLiveText.goNow(called, lang: .en)) == "Go to Triage 1 now")
    }

    @Test func `VoiceOver hears every state in both languages, with no isolates`() throws {
        let cases: [(Visit, Bool, String)] = [
            (try liveVisit(), false, "Al Wakra Health Centre, Your ticket number T-014, Triage, People ahead 3, Estimated wait 12 min"),
            (try liveVisit(ticket: .called), false, "Al Wakra Health Centre, Your ticket number T-014, Triage, Go to Triage 1 now"),
            (try liveVisit(ticket: .serving), false, "Al Wakra Health Centre, Your ticket number T-014, Triage, You are with the team"),
            (try liveVisit(ticket: nil), false, "Al Wakra Health Centre, Next step coming, Triage"),
            (try liveVisit(), true, "Al Wakra Health Centre, Your ticket number T-014, Triage, People ahead 3, Estimated wait 12 min, Updates may be slower."),
        ]
        for (visit, stale, spoken) in cases {
            #expect(TicketLiveText.spoken(state(visit), lang: .en, isStale: stale) == spoken)
        }
        let final = LiveTicketRules.finalState(for: try liveVisit("visit_completed"), lang: .ar)
        #expect(TicketLiveText.spoken(final, lang: .ar, isStale: false) == "مركز الوكرة الصحي, اكتملت الزيارة")
        let arabic = TicketLiveText.spoken(state(try liveVisit(), .ar), lang: .ar, isStale: false)
        #expect(arabic.contains("رقم تذكرتك T-014"))
        #expect(!arabic.unicodeScalars.contains { (0x2066...0x2069).contains($0.value) })
    }

    @Test func `the Island takes the dark values and the Lock Screen follows the scheme`() {
        let island = TicketLiveColors.island()
        let dark = TicketLiveColors(dark: true)
        let light = TicketLiveColors(dark: false)
        #expect(island.hue == dark.hue)
        #expect(island.ink == dark.ink)
        #expect(TicketLiveColors.lockScreen(.light).hue == light.hue)
        #expect(TicketLiveColors.lockScreen(.dark).surface == dark.surface)
        #expect(light.hue != dark.hue)
        #expect(TicketLiveColors.lockScreen(.light, contrast: .increased).hue == TicketLiveColors(dark: false, increasedContrast: true).hue)
    }

    /// SwiftUI views are main-actor types, so their initialisers run on the main actor.
    @MainActor
    @Test func `the views build for every state and presentation`() throws {
        let states = [
            state(try liveVisit()), state(try liveVisit(ticket: .called)),
            state(try liveVisit(ticket: .serving)), state(try liveVisit(ticket: nil)),
            LiveTicketRules.finalState(for: try liveVisit("visit_completed"), lang: .en),
        ]
        #expect(Set(states.map(LiveTicketRules.phase)) == Set(LiveTicketPhase.allCases))
        for state in states {
            for lang in Lang.allCases {
                for stale in [false, true] {
                    _ = TicketLiveLockScreen(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveCompactLeading(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveCompactTrailing(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveMinimal(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveExpandedLeading(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveExpandedTrailing(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveExpandedCenter(state: state, lang: lang, isStale: stale)
                    _ = TicketLiveExpandedBottom(state: state, lang: lang, isStale: stale)
                }
            }
        }
    }
}

/// What the free Personal Team and section 9 forbid, read from the sources that would break it.
@Suite("Live: source guards")
struct LiveSourceGuardTests {
    @Test func `the extension takes its colours from DSPalette, with no hex literal`() throws {
        for file in ["ios/DawriLive/TicketLiveActivity.swift", "ios/DawriLive/DawriLiveBundle.swift"] {
            let text = try Repo.text(file)
            #expect(text.firstMatch(of: #/0x[0-9A-Fa-f]{6}|#[0-9A-Fa-f]{6}\b/#) == nil, "\(file)")
            #expect(!text.contains("footer.ai"), "\(file)")
        }
        let views = try Repo.text("ios/DawriCore/Sources/DawriCore/Live/TicketLiveViews.swift")
        #expect(views.firstMatch(of: #/0x[0-9A-Fa-f]{6}/#) == nil)
        #expect(views.contains("DSPalette.hue"))
    }

    @Test func `the activity asks for no push token, and nothing is time sensitive`() throws {
        let live = try Repo.text("ios/Dawri/Native/TicketLive.swift")
        #expect(live.contains("pushType: nil"))
        #expect(!live.contains("pushType: .token"))
        for file in ["ios/Dawri/Native/TicketLive.swift", "ios/Dawri/Native/VisitNotifier.swift"] {
            let text = try Repo.text(file)
            #expect(!text.contains("timeSensitive"), "\(file)")
            #expect(!text.contains("critical"), "\(file)")
        }
    }
}
