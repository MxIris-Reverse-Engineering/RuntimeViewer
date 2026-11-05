import Foundation
import Semantic

public struct RuntimeInterfaceCorpusBuildSummary: Hashable, Codable, Sendable {
    /// Objects whose interface is in the corpus.
    public let objectCount: Int
    /// Objects whose interface failed to print and were left out. A build
    /// with skipped objects still counts as built.
    public let skippedCount: Int
    /// Resident bytes of the image's corpus: text plus span tables.
    public let byteCount: Int

    public init(objectCount: Int, skippedCount: Int, byteCount: Int) {
        self.objectCount = objectCount
        self.skippedCount = skippedCount
        self.byteCount = byteCount
    }
}
