import DawriCore
import SwiftUI

/// On every patient screen, in the flow. Never truncated: no line limit, no scale factor.
struct PatientFooter: View {
    var tone: ScaffoldTone = .default

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Arabic's footer is a little taller, so at regular sizes the other language holds the
        // space and a switch moves nothing above it.
        ZStack(alignment: .top) {
            lines
            if !typeSize.isAccessibilitySize {
                lines
                    .environment(\.lang, lang == .ar ? .en : .ar)
                    .hidden()
            }
        }
        .foregroundStyle(tone == .emergency ? DS.Emergency.text : DS.Color.muted)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.m)
        .accessibilityElement(children: .contain)
    }

    private var lines: some View {
        FooterLines(showsSimulatedLine: model.showsSimulatedLine)
    }
}

private struct FooterLines: View {
    let showsSimulatedLine: Bool

    @Environment(\.lang) private var lang

    var body: some View {
        VStack(spacing: DS.Space.xxs) {
            Text(verbatim: lang.t("footer.demo"))
                .accessibilityIdentifier("footer")
            if showsSimulatedLine {
                Text(verbatim: lang.t("footer.ai"))
                    .accessibilityIdentifier("footer-ai")
            }
        }
        .dsText(.caption)
    }
}
