import DawriCore
import SwiftUI
import UIKit

enum ScaffoldTone {
    case `default`, emergency
}

enum FooterMode {
    /// The footer is the last thing in the scroll, resting at the bottom on a short screen.
    case flow
    /// In the bottom inset, under a composer. At accessibility sizes it joins the flow, so the
    /// composer keeps its room, and it leaves while the keyboard covers that area.
    case pinned
}

/// Every patient screen, so the bar, gutter and footer cannot differ. The port of
/// frontend/src/components/PatientShell.tsx. Back is the system's: the stack shows it on every
/// pushed screen, and the root has nothing to go back to.
///
/// `pinnedTop` is fixed under the bar, for S08's controls and map. `pinnedBottom` is fixed above
/// the footer inset, for the composer and Call 999. Neither gets a gutter of its own, because
/// the map runs edge to edge and the composer has a fill. `.refreshable` on a scaffold reaches
/// its scroll, and a short screen still pulls.
struct PatientScaffold<Content: View, PinnedTop: View, PinnedBottom: View>: View {
    private let title: String?
    /// The title heads `pinnedTop` instead of the scroll, for S08, whose controls and map sit
    /// under it.
    private let pinsTitle: Bool
    private let showsProductTitle: Bool
    private let tone: ScaffoldTone
    private let footer: FooterMode
    /// The space above the footer. A long screen keeps `xxl`, S01's button rests at `l`.
    private let footerGap: CGFloat
    private let scrollPosition: Binding<ScrollPosition>?
    private let content: Content
    private let pinnedTop: PinnedTop
    private let pinnedBottom: PinnedBottom

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.refresh) private var refresh
    @State private var keyboardIsUp = false

    init(
        title: String? = nil, pinsTitle: Bool = false, showsProductTitle: Bool = true,
        tone: ScaffoldTone = .default,
        footer: FooterMode = .flow, footerGap: CGFloat = DS.Space.xxl,
        scrollPosition: Binding<ScrollPosition>? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder pinnedTop: () -> PinnedTop = { EmptyView() },
        @ViewBuilder pinnedBottom: () -> PinnedBottom = { EmptyView() }
    ) {
        self.title = title
        self.pinsTitle = pinsTitle
        self.showsProductTitle = showsProductTitle
        self.tone = tone
        self.footer = footer
        self.footerGap = footerGap
        self.scrollPosition = scrollPosition
        self.content = content()
        self.pinnedTop = pinnedTop()
        self.pinnedBottom = pinnedBottom()
    }

    var body: some View {
        switch tone {
        case .default: standard
        case .emergency: emergency
        }
    }

    /// Whether the footer sits in the inset. At accessibility sizes it stays in the flow.
    private var pinsFooter: Bool {
        footer == .pinned && !typeSize.isAccessibilitySize
    }

    private var standard: some View {
        // A row, not a top safe area inset, which breaks `containerRelativeFrame` in the scroll.
        VStack(spacing: 0) {
            if pinsTitle, let title {
                ScreenTitle(title)
                    .padding(.horizontal, DS.Space.l)
                    .padding(.bottom, DS.Space.m)
            }
            pinnedTop
            column(tone: .default)
        }
        .background(DS.Color.ground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                pinnedBottom
                if pinsFooter && !keyboardIsUp {
                    PatientFooter()
                        .padding(.horizontal, DS.Space.l)
                        .background(DS.Color.ground)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in
            keyboardIsUp = true
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            keyboardIsUp = false
        }
        .background(NavigationProbe(bridge: model.direction, lang: lang))
        .navigationTitle(title ?? lang.t("common.product"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbarRole(.editor)
        .toolbar {
            ToolbarItem(placement: .principal) {
                if showsProductTitle {
                    // The bar holds its title to its own height, so a long press shows it large.
                    Text(verbatim: lang.t("common.product"))
                        .dsText(.barTitle)
                        .foregroundStyle(DS.Color.ink)
                        .accessibilityShowsLargeContentViewer()
                } else {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                LanguageToggle()
            }
        }
    }

    /// The emergency tone has no bar, and draws its header at the head of the scroll. No back and
    /// no swipe out, in the stack or in a cover. `pinnedBottom` is fixed below the scroll at
    /// every size. See S06 in iOS Design.
    private var emergency: some View {
        PinnedFirstLayout {
            pinnedBottom
                .accessibilitySortPriority(1)
            column(tone: .emergency)
        }
        .accessibilityElement(children: .contain)
        .background(DS.Emergency.field.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .interactiveDismissDisabled()
    }

    private var emergencyHeader: some View {
        HStack(spacing: DS.Space.m) {
            Text(verbatim: lang.t("common.product"))
                .dsText(.barTitle)
                .foregroundStyle(DS.Emergency.text)
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .accessibilityHidden(true)
            Spacer(minLength: DS.Space.s)
            LanguageToggle(tone: .emergency)
                .accessibilitySortPriority(-1)
        }
        .padding(.vertical, DS.Space.xs)
    }

    /// The scroll, with a minimum height of the viewport so the footer rests at the bottom edge
    /// of a short screen and follows the content on a long one.
    private func column(tone: ScaffoldTone) -> some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        if tone == .emergency { emergencyHeader }
                        if let title, !pinsTitle || tone == .emergency {
                            titleView(title, tone: tone)
                        }
                        content
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if !pinsFooter {
                        Color.clear.frame(height: max(0, footerGap - DS.Space.m))
                        PatientFooter(tone: tone)
                            .accessibilitySortPriority(-2)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: viewport.size.height)
            }
            .modifier(OptionalScrollPosition(position: scrollPosition))
            // A short screen has nothing to bounce, but a pull to refresh needs the bounce.
            .scrollBounceBehavior(refresh == nil ? .basedOnSize : .always)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func titleView(_ title: String, tone: ScaffoldTone) -> some View {
        if tone == .emergency {
            Text(verbatim: title)
                .dsText(.emergencyTitle)
                .foregroundStyle(DS.Emergency.text)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
        } else {
            ScreenTitle(title)
        }
    }
}

/// The pinned part, then the scroll. It lays them out the other way up: the scroll on top and the
/// pinned part at the bottom edge. VoiceOver reads in view order, so what is pinned here is
/// reached first. `accessibilitySortPriority` alone cannot do it, because it does not move an
/// element ahead of a scroll view, which is a platform element.
private struct PinnedFirstLayout: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let width = ProposedViewSize(width: bounds.width, height: nil)
        guard let scroll = subviews.last else { return }
        let pinned = subviews.count > 1 ? subviews.first : nil
        let height = pinned?.sizeThatFits(width).height ?? 0
        pinned?.place(
            at: CGPoint(x: bounds.minX, y: bounds.maxY - height), anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: height))
        scroll.place(
            at: bounds.origin, anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height - height))
    }
}

private struct OptionalScrollPosition: ViewModifier {
    let position: Binding<ScrollPosition>?

    func body(content: Content) -> some View {
        if let position {
            content.scrollPosition(position)
        } else {
            content
        }
    }
}
