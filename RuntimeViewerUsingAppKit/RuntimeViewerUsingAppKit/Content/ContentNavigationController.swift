import AppKit
import RuntimeViewerUI

class ContentNavigationController: UXNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
        view.canDrawSubviewsIntoLayer = true
    }
}
