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

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum InspectorRuntimeObjectRoute: Routable {
    case initial
    /// The Hierarchy tab: a class's superclasses, or the protocols a protocol refines.
    case hierarchy
    case relationships
    case specialization
    /// The References tab: callers, callees and type references.
    case references
    /// Forwarded up to `InspectorCoordinator` so it can re-trigger
    /// `InspectorRoute.requestSpecializationSheet` on itself, which
    /// `MainCoordinator` already listens for.
    case requestSpecializationSheet(RuntimeObject)
}
