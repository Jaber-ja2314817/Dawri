import DawriCore
import SwiftUI

/// Every visit screen sits behind this, so a screen a visit has moved past can never render.
/// The port of frontend/src/components/VisitGate.tsx, using the core's `gatedRoute`.
///
/// The model comes in as a parameter, because the watcher is made here and starts from the last
/// visit read: the first frame of a gate after a stage move is the screen, not a skeleton.
struct VisitGate<Content: View>: View {
    private let model: AppModel
    private let id: String
    /// Left out, the gate only sends the visit to its canonical screen.
    private let screen: Screen?
    private let redFlag: Bool
    @ViewBuilder private let content: (Visit, VisitWatcher) -> Content

    @Environment(\.lang) private var lang
    @Environment(\.scenePhase) private var scenePhase
    @State private var watcher: VisitWatcher

    init(
        model: AppModel, id: String, screen: Screen?, redFlag: Bool = false,
        @ViewBuilder content: @escaping (Visit, VisitWatcher) -> Content
    ) {
        self.model = model
        self.id = id
        self.screen = screen
        self.redFlag = redFlag
        self.content = content
        _watcher = State(initialValue: VisitWatcher(id: id, model: model))
    }

    private var route: Route {
        screen.map { .visit(id: id, screen: $0) } ?? .visitRoot(id: id)
    }

    private var title: String {
        lang.t(screen.map { "screen.\($0.rawValue)" } ?? "screen.visit")
    }

    var body: some View {
        Group {
            if let visit = watcher.visit {
                let target = gatedRoute(route, visit: visit)
                if target == route {
                    content(visit, watcher)
                } else {
                    // Never a frame of the old screen, as the web's <Navigate replace>. Nothing
                    // loads here, so it is empty and not a skeleton.
                    PatientScaffold(tone: screen == .emergency ? .emergency : .default) {}
                        .task(id: target) { await model.replace(route, with: target) }
                }
            } else if screen == .emergency {
                // 999 does not wait for this visit to load, or depend on it.
                EmergencyPending(
                    redFlag: redFlag, failure: watcher.state == .failed ? watcher.error : nil
                ) {
                    Task { await watcher.refetch() }
                }
            } else if watcher.state == .failed {
                PatientScaffold(title: title) {
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
        .task(id: id) { await watcher.run() }
        .onChange(of: watcher.state == .gone) { _, gone in
            if gone { model.visitGone() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await watcher.refetch() } }
        }
    }

    private var loading: some View {
        PatientScaffold(title: title) {
            VStack(alignment: .leading, spacing: DS.Space.m) {
                SkeletonBar(width: 200, height: 20)
                SkeletonBar(height: 96)
            }
            // The bars are hidden, so the container says loading, once.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(verbatim: lang.t("common.loading")))
            .accessibilityIdentifier("visit-loading")
            #if DEBUG
            .onAppear { model.demoSkeletons += 1 }
            #endif
        }
    }
}
