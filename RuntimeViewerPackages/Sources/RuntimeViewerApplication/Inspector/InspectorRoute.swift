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

#if os(macOS)
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum InspectorRuntimeObjectRoute: Routable {
    case initial
    case classHierarchy
    case relationships
    case specialization
    /// Forwarded up to `InspectorCoordinator` so it can re-trigger
    /// `InspectorRoute.requestSpecializationSheet` on itself, which
    /// `MainCoordinator` already listens for.
    case requestSpecializationSheet(RuntimeObject)
}
#else
public typealias InspectorRuntimeObjectRoute = InspectorRoute
#endif
