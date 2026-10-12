import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum MainRoute: Routable {
    case main(RuntimeEngine)
    /// The Generation Options popover. Like every route, it carries no view:
    /// `MainCoordinator` takes the toolbar item's button to anchor it at.
    case generationOptions
    case attachToProcess
    /// The MCP status popover, anchored the same way as `generationOptions`.
    case mcpStatus
    case dismiss
    case exportInterfaces
    case exportMultipleImages
    /// Begin the document-window sheet that walks the user through
    /// specializing the supplied generic Swift type. Forwarded by
    /// `InspectorCoordinator` via its delegate.
    case beginSpecializationSheet(RuntimeObject)
    /// Navigate ▸ Reveal in Sidebar Navigator: show the sidebar and have its
    /// object list select and scroll to the object on screen.
    case revealInSidebarNavigator
    /// Edit ▸ Find ▸ Find in Indexed Images…: show the sidebar, switch it to
    /// the Find navigator and focus the search field.
    case find
    /// View ▸ Show Report Navigator: show the sidebar and switch it to the
    /// Report navigator.
    case reports
}
