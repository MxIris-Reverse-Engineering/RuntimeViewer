import AppKit
import AppKitPlus
import RuntimeViewerUI
import RuntimeViewerArchitectures

final class SidebarNavigationController: BaseNavigationController {
    /// Inserts the backdrop under the sliding pages when a push / pop starts and removes it when the
    /// transition completes; see its documentation for what it inserts on which macOS and the
    /// measurements behind that.
    private let navigationTransitionBackdropController = NavigationTransitionBackdropController()

    override func viewDidLoad() {
        super.viewDidLoad()

        delegate = navigationTransitionBackdropController
    }
}
