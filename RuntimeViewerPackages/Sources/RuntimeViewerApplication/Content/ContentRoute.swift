import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum ContentRoute: Routable {
    case placeholder
    case root(RuntimeObject)
    case next(RuntimeObject)
    case back
}
