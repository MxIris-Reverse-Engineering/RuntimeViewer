import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public enum SidebarRoute: Routable {
    case root
    case selectedNode(RuntimeNamedNode)
    case clickedNode(RuntimeNamedNode)
    case selectedObject(RuntimeObjectName)
    case back
}
