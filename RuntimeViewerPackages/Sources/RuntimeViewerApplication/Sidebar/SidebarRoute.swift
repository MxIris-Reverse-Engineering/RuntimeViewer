import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public enum SidebarRoute: Routable {
    case root
    case back
    case selectedNode(RuntimeNamedNode)
    case clickedNode(RuntimeNamedNode)
    case selectedObject(RuntimeObjectName)
}
