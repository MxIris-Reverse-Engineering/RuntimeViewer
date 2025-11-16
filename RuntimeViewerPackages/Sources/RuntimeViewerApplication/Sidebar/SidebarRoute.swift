import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SidebarRoute: Routable {
    case root
    case back
    case selectedNode(RuntimeImageNode)
    case clickedNode(RuntimeImageNode)
    case selectedObject(RuntimeObjectName)
}
