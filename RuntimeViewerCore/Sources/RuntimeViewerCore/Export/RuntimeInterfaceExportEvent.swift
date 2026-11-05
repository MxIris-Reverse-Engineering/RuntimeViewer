import Foundation
public import Semantic

public enum RuntimeInterfaceExportEvent: Sendable {
    case phaseStarted(Phase)
    case phaseCompleted(Phase)
    case phaseFailed(Phase, any Swift.Error & Sendable)

    case objectStarted(RuntimeObject, current: Int, total: Int)
    case objectCompleted(RuntimeObject, FrozenSemanticString)
    case objectFailed(RuntimeObject, any Swift.Error & Sendable)

    case completed(RuntimeInterfaceExportResult)

    public enum Phase: Sendable {
        case preparing
        case exporting
        case writing
    }
}
