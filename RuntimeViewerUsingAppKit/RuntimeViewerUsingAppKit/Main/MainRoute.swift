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
    case select(RuntimeObjectName)
    case sidebarBack
    case contentBack
    case generationOptions(sender: NSView)
    case loadFramework
    case attachToProcess
    case dismiss
}
