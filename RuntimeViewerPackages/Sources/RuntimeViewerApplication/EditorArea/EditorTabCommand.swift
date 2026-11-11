import Foundation

/// A command an editor tab's context menu offers: closing tabs, and the
/// commands every list offers on the object the tab shows.
public enum EditorTabCommand: Hashable, Sendable {
    /// Close Tab.
    case close

    /// Close Other Tabs: every other tab of the tab's pane.
    case closeOthers

    /// Close Tabs to the Right: the tabs after this one in its pane.
    case closeToTheRight

    /// A command on the object the tab shows (`RuntimeObjectAction`).
    case runtimeObjectAction(RuntimeObjectAction)
}
