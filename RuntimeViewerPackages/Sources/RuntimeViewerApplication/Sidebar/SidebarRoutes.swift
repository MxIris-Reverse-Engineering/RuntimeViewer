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
    case selectedObject(RuntimeObject)
    case exportInterface
}

#if os(macOS)
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SidebarRootRoute: Routable {
    case initial
    case directory
    case bookmarks
    case image(RuntimeImageNode)
}
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SidebarRuntimeObjectRoute: Routable {
    case initial
    case objects
    case bookmarks
    case selectedObject(RuntimeObject)
    case exportInterface
}
#else
public typealias SidebarRootRoute = SidebarRoute
public typealias SidebarRuntimeObjectRoute = SidebarRoute
#endif





