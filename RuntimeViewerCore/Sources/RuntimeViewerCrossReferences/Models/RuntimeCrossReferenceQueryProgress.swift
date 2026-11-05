import Foundation
import RuntimeViewerCore

/// How far a scan across images has come, with what it found since the last
/// report — so a caller that gives up early still has those. Over a whole
/// query the reports carry exactly the references of the result.
public struct RuntimeCrossReferenceQueryProgress: Hashable, Codable, Sendable {
    public let scannedImageCount: Int
    public let totalImageCount: Int
    public let references: [RuntimeCrossReference]

    public init(scannedImageCount: Int, totalImageCount: Int, references: [RuntimeCrossReference]) {
        self.scannedImageCount = scannedImageCount
        self.totalImageCount = totalImageCount
        self.references = references
    }
}
