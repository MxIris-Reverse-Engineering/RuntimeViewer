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
    /// User clicked "Add Specialization" on the Inspector's Specialization tab.
    /// Bubbles to `MainCoordinator` so it can begin the document-window sheet.
    case requestSpecializationSheet(RuntimeObject)
    /// User clicked an existing specialized child in the Specialization list.
    /// Bubbles to `MainCoordinator` so it can update
    /// `documentState.selectedRuntimeObject` (which the sidebar mirrors).
    case selectRuntimeObject(RuntimeObject)
}
