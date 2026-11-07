import DawriCore
import SwiftUI
import UIKit

/// SwiftUI's `layoutDirection` alone does not reach the UIKit that hosts a `NavigationStack`:
/// the bar's back chevron, the push direction and the swipe-back edge all come from UIKit
/// semantics. This keeps them in step with the language without rebuilding anything.
///
/// The appearance proxies cover views made from now on. Views that already exist are set
/// directly: the window, each navigation controller's view, its bar and its pop gesture.
@MainActor
final class DirectionBridge {
    private(set) var lang: Lang
    private weak var window: UIWindow?
    private weak var navigationController: UINavigationController?

    init(initial: Lang) {
        lang = initial
        applyProxies(initial)
    }

    /// True from the moment a finger starts a swipe back until it lands.
    var isSwipingBack: Bool {
        navigationController?.transitionCoordinator?.isInteractive ?? false
    }

    func attach(window: UIWindow) {
        self.window = window
        applyToWindow()
    }

    func attach(navigationController: UINavigationController) {
        self.navigationController = navigationController
        applyToNavigation()
    }

    func apply(_ next: Lang) {
        lang = next
        applyProxies(next)
        applyToWindow()
        applyToNavigation()
    }

    /// The language switch's cross-fade. It has no travel, so Reduce Motion needs no other path.
    func crossfade(_ change: () -> Void) {
        guard let window else {
            change()
            return
        }
        UIView.transition(
            with: window, duration: DS.Motion.crossfadeSeconds,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: { UIView.performWithoutAnimation(change) })
    }

    private var attribute: UISemanticContentAttribute {
        lang.dir == .rtl ? .forceRightToLeft : .forceLeftToRight
    }

    private func applyProxies(_ lang: Lang) {
        let value: UISemanticContentAttribute = lang.dir == .rtl ? .forceRightToLeft : .forceLeftToRight
        UIView.appearance().semanticContentAttribute = value
        UINavigationBar.appearance().semanticContentAttribute = value
        // What VoiceOver speaks the app's elements in, whatever the phone's own language is.
        UIApplication.shared.accessibilityLanguage = lang.rawValue
    }

    private func applyToWindow() {
        guard let window else { return }
        window.semanticContentAttribute = attribute
        window.traitOverrides.layoutDirection = lang.dir == .rtl ? .rightToLeft : .leftToRight
    }

    private func applyToNavigation() {
        guard let navigationController else { return }
        navigationController.view.semanticContentAttribute = attribute
        let bar = navigationController.navigationBar
        applyDown(bar)
        bar.setNeedsLayout()
        navigationController.viewControllers.forEach(nameBack)
    }

    /// The system's back button is named after the previous screen. This has VoiceOver say Back
    /// in the app's language instead. A screen's back item is the one shown on the screen above
    /// it, so it is set on every entry. The button's own identifier stays UIKit's `BackButton`:
    /// nothing public changes it, and `accessibilityIdentifier` here does not reach it.
    private func nameBack(from controller: UIViewController) {
        let item = controller.navigationItem.backBarButtonItem ?? UIBarButtonItem()
        item.title = controller.navigationItem.title
        item.accessibilityLabel = lang.t("common.back")
        if controller.navigationItem.backBarButtonItem !== item {
            controller.navigationItem.backBarButtonItem = item
        }
    }

    private func applyDown(_ view: UIView) {
        view.semanticContentAttribute = attribute
        view.subviews.forEach(applyDown)
    }
}

/// Reports the window to the bridge as soon as there is one.
struct WindowProbe: UIViewRepresentable {
    let bridge: DirectionBridge

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.bridge = bridge
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        var bridge: DirectionBridge?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { bridge?.attach(window: window) }
        }
    }
}

/// Sits behind each screen, and reports the screen's navigation controller to the bridge.
struct NavigationProbe: UIViewControllerRepresentable {
    let bridge: DirectionBridge
    let lang: Lang

    func makeUIViewController(context: Context) -> ProbeController {
        let controller = ProbeController()
        controller.bridge = bridge
        return controller
    }

    func updateUIViewController(_ controller: ProbeController, context: Context) {
        controller.report()
    }

    final class ProbeController: UIViewController {
        var bridge: DirectionBridge?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            report()
        }

        func report() {
            if let navigationController { bridge?.attach(navigationController: navigationController) }
        }
    }
}
