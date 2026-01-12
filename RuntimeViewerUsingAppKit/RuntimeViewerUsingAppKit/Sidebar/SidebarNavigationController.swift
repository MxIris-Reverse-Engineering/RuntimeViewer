import AppKit
import RuntimeViewerUI

final class SidebarNavigationController: UXKitNavigationController {}

extension SidebarNavigationController {
    func navigationController(_ navigationController: UXNavigationController, willShow viewController: UXViewController) {
        if #available(macOS 26.0, *) {
            guard let coordinator = navigationController.transitionCoordinator,
                  let fromViewController = coordinator.viewController(forKey: .from),
                  let toViewController = coordinator.viewController(forKey: .to)
            else { return }

            let fromOriginalBackgroundColor = fromViewController.uxView.backgroundColor
            let toOriginalBackgroundColor = toViewController.uxView.backgroundColor
            coordinator.animate(alongsideTransition: { context in
                fromViewController.uxView.backgroundColor = .windowBackgroundColor
                toViewController.uxView.backgroundColor = .windowBackgroundColor
            }, completion: { context in
                fromViewController.uxView.backgroundColor = fromOriginalBackgroundColor
                toViewController.uxView.backgroundColor = toOriginalBackgroundColor
            })
        }
    }

    func navigationController(_ navigationController: UXNavigationController, didShow viewController: UXViewController) {
        if #available(macOS 26.0, *) {
            navigationController.view.needsDisplay = true
        }
    }
}
