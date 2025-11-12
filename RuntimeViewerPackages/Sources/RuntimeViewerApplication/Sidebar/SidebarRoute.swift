import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public enum SidebarRoute: Routable {
    case root
    case back
    case selectedNode(RuntimeImageNode)
    case clickedNode(RuntimeImageNode)
    case selectedObject(RuntimeObjectName)
}
