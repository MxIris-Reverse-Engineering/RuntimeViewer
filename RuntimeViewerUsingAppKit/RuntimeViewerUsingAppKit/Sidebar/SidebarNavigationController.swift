import AppKit
import RuntimeViewerUI

/// - Note: This used to carry a macOS 26 workaround: during a push it forced both the outgoing
///   and incoming views to `windowBackgroundColor` and restored their real colours afterwards,
///   because UXKit otherwise let the wrong colour show through mid-transition. It was written
///   against `UXNavigationController.transitionCoordinator` and
///   `animate(alongsideTransition:completion:)`, neither of which `NavigationController` has.
///
///   It was dropped rather than re-expressed through `willShow` / `didShow`, because the artefact
///   it hid was very likely UXKit's own — a different container composites the transition
///   differently. **This needs a look on macOS 26**: push into an image's object list and watch
///   the background during the slide. If the wrong colour is back, reinstate it via
///   `NavigationControllerDelegate`, which fires either side of the same transition.
final class SidebarNavigationController: BaseNavigationController {
    
    
    
    override func viewDidLoad() {
        super.viewDidLoad()
        var newConfiguration = NavigationConfiguration.uiKit
        newConfiguration.pageBackdrop = .view( { LayerBackedView().then { $0.backgroundColor = .windowBackgroundColor } } )
        configuration = newConfiguration
    }
}
