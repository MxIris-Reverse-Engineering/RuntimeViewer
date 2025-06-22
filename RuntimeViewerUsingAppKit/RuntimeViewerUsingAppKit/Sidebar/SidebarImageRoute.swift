import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public enum SidebarImageRoute: Routable {
    case root
    case back
    case selectedNode(RuntimeNamedNode)
    case clickedNode(RuntimeNamedNode)
    case selectedObject(RuntimeObjectName)
}
