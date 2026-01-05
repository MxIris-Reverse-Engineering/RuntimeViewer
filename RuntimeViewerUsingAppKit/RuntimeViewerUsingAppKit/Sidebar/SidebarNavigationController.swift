import AppKit
import RuntimeViewerUI

final class SidebarNavigationController: UXKitNavigationController {}

extension SidebarNavigationController {
    func navigationController(_ navigationController: UXNavigationController, willShow viewController: UXViewController) {
        if #available(macOS 26.0, *) {
            guard let coordinator = navigationController.transitionCoordinator, let fromViewController = coordinator.viewController(forKey: .from), navigationController.viewControllers.contains(fromViewController) else {
                return
            }

            let topViewController = navigationController.topViewController
            let originalBackgroundColor = topViewController?.uxView.backgroundColor
            coordinator.animate(alongsideTransition: { context in
                topViewController?.uxView.backgroundColor = .windowBackgroundColor
            }, completion: { context in
                topViewController?.uxView.backgroundColor = originalBackgroundColor
            })
        }
    }

    func navigationController(_ navigationController: UXNavigationController, didShow viewController: UXViewController) {
        if #available(macOS 26.0, *) {
            navigationController.view.needsDisplay = true
        }
    }
    
//    func navigationController(_ navigationController: UXNavigationController, animationControllerFor operation: UXNavigationController.Operation, from fromViewController: UXViewController, to toViewController: UXViewController) -> (any UXViewControllerAnimatedTransitioning)? {
//        return NoAnimationTransition.shared
//    }
}


