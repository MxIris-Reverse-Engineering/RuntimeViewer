public import Foundation
import Semantic

public struct RuntimeInterfaceExportResult: Sendable, Equatable {
    public let succeeded: Int
    public let failed: Int
    public let totalDuration: TimeInterval
    public let objcCount: Int
    public let swiftCount: Int
    public let cPlusPlusCount: Int

    public init(succeeded: Int, failed: Int, totalDuration: TimeInterval, objcCount: Int, swiftCount: Int, cPlusPlusCount: Int = 0) {
        self.succeeded = succeeded
        self.failed = failed
        self.totalDuration = totalDuration
        self.objcCount = objcCount
        self.swiftCount = swiftCount
        self.cPlusPlusCount = cPlusPlusCount
    }
}
