import DawriCore
import SwiftUI

enum ScaffoldTone {
    case `default`, emergency
}

enum FooterMode {
    /// The footer is the last thing in the scroll, resting at the bottom on a short screen.
    case flow
    /// In the bottom inset, under a composer. At accessibility sizes it joins the flow, so the
    /// composer keeps its room.
    case pinned
}

/// Every patient screen, so the bar, gutter and footer cannot differ. The port of
/// frontend/src/components/PatientShell.tsx. Back is the system's: the stack shows it on every
/// pushed screen, and the root has nothing to go back to.
struct PatientScaffold<Content: View>: View {
    var title: String?
    var showsProductTitle = true
    var tone: ScaffoldTone = .default
    var footer: FooterMode = .flow
    /// The space above the footer. A long screen keeps `xxl`, S01's button rests at `l`.
    var footerGap: CGFloat = DS.Space.xxl
    @ViewBuilder var content: Content

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        Group {
            switch tone {
            case .default: standard
            case .emergency: emergency
            }
        }
        .background(NavigationProbe(bridge: model.direction, lang: lang))
    }

    private var pinsFooter: Bool {
        footer == .pinned && !typeSize.isAccessibilitySize
    }

    private var standard: some View {
        column(tone: .default)
            .background(DS.Color.ground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if pinsFooter {
                    PatientFooter()
                        .padding(.horizontal, DS.Space.l)
                        .background(DS.Color.ground)
                }
            }
            .navigationTitle(title ?? lang.t("common.product"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    if showsProductTitle {
                        Text(verbatim: lang.t("common.product"))
                            .dsText(.barTitle)
                            .foregroundStyle(DS.Color.ink)
                    } else {
                        Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    LanguageToggle()
                }
            }
    }

    /// The emergency tone drops the toolbar and draws its own header. No back, and no swipe out.
    private var emergency: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                Text(verbatim: lang.t("common.product"))
                    .dsText(.barTitle)
                    .foregroundStyle(DS.Emergency.text)
                    .accessibilityHidden(true)
                Spacer(minLength: DS.Space.s)
                LanguageToggle(tone: .emergency)
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.vertical, DS.Space.xs)
            column(tone: .emergency)
        }
        .background(DS.Emergency.field.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    /// The scroll, with a minimum height of the viewport so the footer rests at the bottom edge
    /// of a short screen and follows the content on a long one.
    private func column(tone: ScaffoldTone) -> some View {
        GeometryReader { viewport in
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: DS.Space.m) {
                        if let title {
                            titleView(title, tone: tone)
                        }
                        content
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    if !pinsFooter {
                        Color.clear.frame(height: max(0, footerGap - DS.Space.m))
                        PatientFooter(tone: tone)
                    }
                }
                .padding(.horizontal, DS.Space.l)
                .frame(minHeight: viewport.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.interactively)
        }
    }

    @ViewBuilder
    private func titleView(_ title: String, tone: ScaffoldTone) -> some View {
        if tone == .emergency {
            Text(verbatim: title)
                .dsText(.emergencyTitle)
                .foregroundStyle(DS.Emergency.text)
                .accessibilityAddTraits(.isHeader)
        } else {
            ScreenTitle(title)
        }
    }
}
