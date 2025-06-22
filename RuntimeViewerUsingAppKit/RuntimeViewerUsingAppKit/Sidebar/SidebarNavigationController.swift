import AppKit
import RuntimeViewerUI

class SidebarNavigationController: UXNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        view.canDrawSubviewsIntoLayer = true
    }
}
