public import Foundation
import Semantic

public struct RuntimeInterfaceExportResult: Sendable, Equatable {
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
