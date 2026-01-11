import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

public enum InspectableObject {
    case node(RuntimeImageNode)
    case object(RuntimeObject)
}

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum InspectorRoute: Routable {
    case placeholder
    case root(InspectableObject)
    case next(InspectableObject)
    case back
}
