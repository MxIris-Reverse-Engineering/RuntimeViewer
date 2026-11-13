#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import CocoaCoordinator

/// Drives AppKitPlus's `NSNavigationController` from a CocoaCoordinator route.
///
/// Replaces the equivalent extension `UXKitCoordinator` provided for `UXNavigationController`.
/// Same five operations, same call sites; the stack now takes plain `NSViewController`s, so the
/// old `as? UXViewController` downcast — and the `logger.fault` for when it failed — has no
/// counterpart here.
///
/// **Completion runs synchronously, before any animation finishes.** `NSNavigationController`'s
/// stack API takes no completion handler, matching `UINavigationController`; the only "it settled"
/// signal is `NSNavigationControllerDelegate.navigationController(_:didShow:)`, and routing every
/// transition through that would mean queueing completions on the controller and contending with
/// the delegate a subclass may want for itself (`SidebarNavigationController` does). The
/// `UXKitCoordinator` layer this replaces called completion synchronously too, so the behaviour is
/// unchanged. What the completion actually reaches is `Presentable.presented(from:)`, whose default
/// implementation is empty and which nothing in CocoaCoordinator or this app overrides — so nobody
/// can observe the difference today. Anything that starts overriding `presented(from:)` and depends
/// on the animation having ended has to revisit this.
extension Transition where ViewController: NSNavigationController {
    public static func push(_ presentable: ViewPresentable, animated: Bool) -> Self {
        Self(presentables: [presentable]) { _, navigationController, _, completion in
            navigationController?.pushViewController(presentable.viewController, animated: animated)
            presentable.presented(from: navigationController)
            completion?()
        }
    }

    public static func pop(animated: Bool) -> Self {
        Self(presentables: []) { _, navigationController, _, completion in
            navigationController?.popViewController(animated: animated)
            completion?()
        }
    }

    public static func pop(to presentable: ViewPresentable, animated: Bool) -> Self {
        Self(presentables: [presentable]) { _, navigationController, _, completion in
            navigationController?.popToViewController(presentable.viewController, animated: animated)
            completion?()
        }
    }

    public static func popToRoot(animated: Bool) -> Self {
        Self(presentables: []) { _, navigationController, _, completion in
            navigationController?.popToRootViewController(animated: animated)
            completion?()
        }
    }

    public static func set(_ presentables: [ViewPresentable], animated: Bool) -> Self {
        Self(presentables: presentables) { _, navigationController, _, completion in
            navigationController?.setViewControllers(presentables.map(\.viewController), animated: animated)
            presentables.forEach { $0.presented(from: navigationController) }
            completion?()
        }
    }
}

#endif
