import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum MainRoute: Routable {
    case main(RuntimeEngine)
    case generationOptions(sender: NSView)
    case attachToProcess
    case mcpStatus(sender: NSView)
    case backgroundIndexing(sender: NSView)
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
}
