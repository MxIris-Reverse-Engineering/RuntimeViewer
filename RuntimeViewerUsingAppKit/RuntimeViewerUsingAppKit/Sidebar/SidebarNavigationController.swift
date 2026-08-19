import AppKit
import AppKitPlus
import RuntimeViewerUI

final class SidebarNavigationController: BaseNavigationController, NSNavigationControllerDelegate {
    override func viewDidLoad() {
        super.viewDidLoad()

        delegate = self
    }

    func navigationController(_ navigationController: NSNavigationController, willShow viewController: NSViewController) {
        if #available(macOS 26.0, *) {
            guard let coordinator = navigationController.transitionCoordinator,
                  let fromViewController = coordinator.viewController(forKey: .from),
                  let toViewController = coordinator.viewController(forKey: .to)
            else { return }

            let fromOriginalBackgroundColor = fromViewController.view.backgroundColor
            let toOriginalBackgroundColor = toViewController.view.backgroundColor
            coordinator.animate(alongsideTransition: { context in
                fromViewController.view.backgroundColor = .windowBackgroundColor
                toViewController.view.backgroundColor = .windowBackgroundColor
            }, completion: { context in
                fromViewController.view.backgroundColor = fromOriginalBackgroundColor
                toViewController.view.backgroundColor = toOriginalBackgroundColor
            })
        }
    }

    func navigationController(_ navigationController: NSNavigationController, didShow viewController: NSViewController) {
        if #available(macOS 26.0, *) {
            navigationController.view.needsDisplay = true
        }
    }
}

extension SidebarNavigationController {

}
