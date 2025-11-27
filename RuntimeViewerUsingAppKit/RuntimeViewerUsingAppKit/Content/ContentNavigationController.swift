import AppKit
import RuntimeViewerUI

final class ContentNavigationController: UXNavigationController {
    override func viewDidLoad() {
        super.viewDidLoad()

        isToolbarHidden = true
        isNavigationBarHidden = true
    }
}
