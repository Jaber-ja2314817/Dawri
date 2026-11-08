#if DEBUG
import DawriCore
import SwiftUI

/// `-demoScreen live [-demoPage <state>]`: every presentation of the Live Activity, from the same
/// `TicketLive…` views the widget extension draws, in the screen's language and theme. The Lock
/// Screen follows the theme. The Island shapes are always black, as the real Island is, and
/// their content always takes the dark values. Sample data only, written here for the review.
struct LiveGallery: View {
    /// One row of the gallery: a state and whether the system marked it stale.
    enum Page: String, CaseIterable {
        case active, called, serving, between, stale, ended
    }

    @Environment(\.lang) private var lang
    @Environment(\.colorScheme) private var scheme

    private var pages: [Page] {
        DemoLaunch.current?.argument("demoPage").flatMap(Page.init(rawValue:)).map { [$0] } ?? Page.allCases
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.xl) {
                ForEach(pages, id: \.self) { page in
                    section(page)
                }
            }
            .padding(DS.Space.l)
        }
        .background(DS.Color.ground.ignoresSafeArea())
        .accessibilityIdentifier("live-gallery")
    }

    private func sample(_ page: Page) -> TicketLiveState {
        let centre = lang == .ar ? "مركز الوكرة الصحي" : "Al Wakra Health Centre"
        let counter = lang == .ar ? "الفرز 1" : "Triage 1"
        var state = TicketLiveState(
            number: "T-014", stage: .triage, peopleAhead: 3, estWaitMin: 12, counter: counter,
            ticketState: .active, centreName: centre)
        switch page {
        case .active, .stale:
            break
        case .called:
            state.ticketState = .called
            state.peopleAhead = 0
            state.estWaitMin = 0
        case .serving:
            state.ticketState = .serving
            state.peopleAhead = 0
            state.estWaitMin = 0
        case .between:
            state = TicketLiveState(
                number: nil, stage: .doctor, peopleAhead: nil, estWaitMin: nil, counter: "",
                ticketState: nil, centreName: centre)
        case .ended:
            state = TicketLiveState(
                number: nil, stage: .completed, peopleAhead: nil, estWaitMin: nil, counter: "",
                ticketState: nil, centreName: centre)
        }
        return state
    }

    private func section(_ page: Page) -> some View {
        let state = sample(page)
        let stale = page == .stale
        return VStack(alignment: .leading, spacing: DS.Space.m) {
            Text(verbatim: "Live: \(page.rawValue)")
                .dsText(.caption)
                .foregroundStyle(DS.Color.muted)
                .environment(\.layoutDirection, .leftToRight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)

            // Lock Screen, on the surface the extension tints it with.
            TicketLiveLockScreen(state: state, lang: lang, isStale: stale)
                .background(
                    TicketLiveColors.lockScreen(scheme).surface,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(DS.Color.hairline, lineWidth: DS.Stroke.edge))
                .accessibilityIdentifier("live-lock-\(page.rawValue)")

            // Compact and minimal, as the Island draws them around the camera.
            HStack(spacing: DS.Space.m) {
                HStack(spacing: 0) {
                    TicketLiveCompactLeading(state: state, lang: lang, isStale: stale)
                    Spacer(minLength: 96)
                    TicketLiveCompactTrailing(state: state, lang: lang, isStale: stale)
                }
                .padding(.horizontal, 14)
                .frame(height: 37)
                .frame(maxWidth: 250)
                .background(Color.black, in: Capsule())
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("live-compact-\(page.rawValue)")

                TicketLiveMinimal(state: state, lang: lang, isStale: stale)
                    .frame(width: 37, height: 37)
                    .background(Color.black, in: Circle())
                    .accessibilityIdentifier("live-minimal-\(page.rawValue)")
                Spacer(minLength: 0)
            }
            .environment(\.layoutDirection, .leftToRight)

            // Expanded: leading, centre and trailing, then the bottom.
            VStack(spacing: DS.Space.s) {
                HStack(alignment: .top, spacing: DS.Space.s) {
                    TicketLiveExpandedLeading(state: state, lang: lang, isStale: stale)
                    TicketLiveExpandedCenter(state: state, lang: lang, isStale: stale)
                        .padding(.top, DS.Space.xs)
                    TicketLiveExpandedTrailing(state: state, lang: lang, isStale: stale)
                }
                TicketLiveExpandedBottom(state: state, lang: lang, isStale: stale)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 44, style: .continuous))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("live-expanded-\(page.rawValue)")
        }
    }
}
#endif
