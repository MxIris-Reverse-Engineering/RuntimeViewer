import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum ContentRoute: Routable {
    case placeholder
    case root(RuntimeObjectName)
    case next(RuntimeObjectName)
    case back
}
