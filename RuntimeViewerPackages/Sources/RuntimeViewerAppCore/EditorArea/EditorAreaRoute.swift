import Foundation
import FoundationToolbox
import RuntimeViewerArchitectures

/// What the editor area's coordinator does: bring its panes in line with
/// `DocumentState.editorArea`, and show what a `SelectionRoute` asked for in
/// the pane it went to.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum EditorAreaRoute: Routable {
    /// Makes the panes the editor area holds, lets go of the ones it no longer
    /// holds, arranges them and shows each pane's active tab.
    case sync

    /// `sync`, after `route` changed the editor area: the pane the route went
    /// to is shown the way the route asks — a new tab starts the pane over, a
    /// Find hit is revealed.
    case apply(SelectionRoute)
}
