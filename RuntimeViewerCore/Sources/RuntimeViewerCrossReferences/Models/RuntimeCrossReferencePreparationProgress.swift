import Foundation
import RuntimeViewerCore

/// How far an image's preparation has come: its functions scanned so far,
/// then the names its answers are shown with being read.
public struct RuntimeCrossReferencePreparationProgress: Hashable, Codable, Sendable {
    public let scannedFunctionCount: Int
    public let functionCount: Int
    /// Every function is scanned; the names of its functions, classes and
    /// types are being read, so that the first query names what it finds
    /// without reading them.
    public let isReadingNames: Bool

    public init(scannedFunctionCount: Int, functionCount: Int, isReadingNames: Bool = false) {
        self.scannedFunctionCount = scannedFunctionCount
        self.functionCount = functionCount
        self.isReadingNames = isReadingNames
    }

    /// Whether this report comes after `other` in a preparation: reports
    /// travel on their own and may arrive out of order.
    public func isAhead(of other: RuntimeCrossReferencePreparationProgress) -> Bool {
        (isReadingNames ? 1 : 0, scannedFunctionCount) > (other.isReadingNames ? 1 : 0, other.scannedFunctionCount)
    }
}
