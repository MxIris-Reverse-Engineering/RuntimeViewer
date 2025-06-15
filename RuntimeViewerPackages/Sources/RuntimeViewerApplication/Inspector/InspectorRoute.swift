import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

public enum InspectableObject {
    case node(RuntimeNamedNode)
    case object(RuntimeObjectType)
}

public enum InspectorRoute: Routable {
    case placeholder
    case root(InspectableObject)
    case next(InspectableObject)
    case back
}
