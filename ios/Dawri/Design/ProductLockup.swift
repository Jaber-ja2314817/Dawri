import DawriCore
import SwiftUI

/// The mark, then the Latin name. The same in both languages, so nothing changes shape on a
/// switch. Start-aligned, and the wordmark is never flipped.
struct ProductLockup: View {
    @Environment(\.lang) private var lang

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Image("Wordmark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: DS.Size.markWidth, height: DS.Size.markHeight)
                .foregroundStyle(DS.Color.ink)
            Text(verbatim: "Dawri")
                .dsText(.section)
                .foregroundStyle(DS.Color.ink)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: lang.t("common.product")))
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("product-lockup")
    }
}
