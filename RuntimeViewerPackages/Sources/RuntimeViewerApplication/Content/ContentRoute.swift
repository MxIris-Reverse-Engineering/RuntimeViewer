import Foundation
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

public enum ContentRoute: Routable {
    case placeholder
    case root(RuntimeObjectName)
    case next(RuntimeObjectName)
    case back
}
