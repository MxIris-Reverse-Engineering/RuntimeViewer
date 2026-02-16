public import Foundation
public import Semantic

public enum RuntimeInterfaceExportEvent: Sendable {
    case phaseStarted(Phase)
    case phaseCompleted(Phase)
    case phaseFailed(Phase, any Swift.Error & Sendable)

    case objectStarted(RuntimeObject, current: Int, total: Int)
    case objectCompleted(RuntimeObject, SemanticString)
    case objectFailed(RuntimeObject, any Swift.Error & Sendable)

    case completed(RuntimeInterfaceExportResult)

    public enum Phase: Sendable {
        case preparing
        case exporting
        case writing
    }
}

public struct RuntimeInterfaceExportResult: Sendable {
    public let succeeded: Int
    public let failed: Int
    public let totalDuration: TimeInterval
    public let objcCount: Int
    public let swiftCount: Int

    public init(succeeded: Int, failed: Int, totalDuration: TimeInterval, objcCount: Int, swiftCount: Int) {
        self.succeeded = succeeded
        self.failed = failed
        self.totalDuration = totalDuration
        self.objcCount = objcCount
        self.swiftCount = swiftCount
    }
}
