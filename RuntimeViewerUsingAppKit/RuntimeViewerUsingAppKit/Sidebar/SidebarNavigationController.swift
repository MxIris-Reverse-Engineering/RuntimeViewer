import AppKit
import RuntimeViewerUI

class SidebarNavigationController: UXNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        delegate = self
    }
}

extension SidebarNavigationController: UXNavigationControllerDelegate {
    func navigationController(_ navigationController: UXNavigationController, willShow viewController: UXViewController) {
        guard let coordinator = navigationController.transitionCoordinator, let fromViewController = coordinator.viewController(forKey: .from), navigationController.viewControllers.contains(fromViewController) else {
            return
        }

        // The original background color
        let topViewController = navigationController.topViewController
        let originalBackgroundColor = topViewController?.uxView.backgroundColor
        // Run our code alongside the transition animation
        coordinator.animate(alongsideTransition: { context in
            // During the animation, set a solid background color
            topViewController?.uxView.backgroundColor = .windowBackgroundColor
        }, completion: { context in
            // After the animation completes...
            topViewController?.uxView.backgroundColor = originalBackgroundColor
        })
    }

    func navigationController(_ navigationController: UXNavigationController, didShow viewController: UXViewController) {
        navigationController.view.needsDisplay = true
    }
}
