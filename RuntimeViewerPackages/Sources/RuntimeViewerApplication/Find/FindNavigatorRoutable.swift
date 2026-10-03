import RuntimeViewerArchitectures
import UIFoundation

/// The routes of a sidebar level that has the Find navigator among its tabs.
///
/// The page is a tab of both sidebar levels, and what it opens is presented
/// by whichever level it is on, so the page asks its own router through this
/// requirement rather than naming either level's route.
public protocol FindNavigatorRoutable: Routable {
    /// The scope chooser, as a popover anchored at `sender`.
    static func findScopeChooser(sender: NSUIView) -> Self
}
