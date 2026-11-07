import DawriCore
import SwiftUI

/// Every visit screen sits behind this, so a screen a visit has moved past can never render.
/// The port of frontend/src/components/VisitGate.tsx, using the core's `gatedRoute`.
struct VisitGate<Content: View>: View {
    let id: String
    /// Left out, the gate only sends the visit to its canonical screen.
    let screen: Screen?
    @ViewBuilder let content: (Visit, VisitWatcher) -> Content

    @Environment(AppModel.self) private var model
    @Environment(\.lang) private var lang
    @State private var watcher: VisitWatcher?

    private var route: Route {
        screen.map { .visit(id: id, screen: $0) } ?? .visitRoot(id: id)
    }

    private var tone: ScaffoldTone {
        screen == .emergency ? .emergency : .default
    }

    private var title: String {
        lang.t(screen.map { "screen.\($0.rawValue)" } ?? "screen.visit")
    }

    var body: some View {
        Group {
            if let watcher, let visit = watcher.visit {
                let target = gatedRoute(route, visit: visit)
                if target == route {
                    content(visit, watcher)
                } else {
                    // Never a frame of the old screen: the same as the web's <Navigate replace>.
                    loading
                        .task(id: target) { await model.replace(route, with: target) }
                }
            } else if let watcher, watcher.state == .failed {
                PatientScaffold(title: title, tone: tone) {
                    ErrorBlock(
                        message: errorText(
                            watcher.error ?? ClinicError.network, strings: .bundled, lang: lang)
                    ) {
                        Task { await watcher.refetch() }
                    }
                }
            } else {
                loading
            }
        }
        .task(id: id) {
            let watcher = VisitWatcher(id: id, service: model.service)
            self.watcher = watcher
            await watcher.run()
        }
        .onChange(of: watcher?.state == .gone) { _, gone in
            if gone { model.visitGone() }
        }
    }

    private var loading: some View {
        PatientScaffold(title: title, tone: tone) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SkeletonBar(width: 200, height: 20)
                SkeletonBar(height: 96)
            }
            .accessibilityIdentifier("visit-loading")
        }
    }
}
