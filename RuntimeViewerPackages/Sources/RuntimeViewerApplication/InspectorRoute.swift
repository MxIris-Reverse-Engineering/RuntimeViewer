import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public enum InspectableType {
    case node(RuntimeNamedNode)
    case object(RuntimeObjectType)
}

public enum InspectorRoute: Routable {
    case root
    case select(InspectableType)
}
