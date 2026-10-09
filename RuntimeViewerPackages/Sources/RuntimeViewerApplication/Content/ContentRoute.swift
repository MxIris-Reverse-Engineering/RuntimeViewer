import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum ContentRoute: Routable {
    case placeholder
    case root(RuntimeObject)
    /// `root`, with where in the interface to scroll and flash once it is first on screen: a
    /// Find navigator hit opened in a new tab.
    case rootHighlighting(RuntimeObject, ContentHighlightRequest)
    case next(RuntimeObject)
    /// `next`, with the same: a Find navigator hit.
    case nextHighlighting(RuntimeObject, ContentHighlightRequest)
    case back
}
