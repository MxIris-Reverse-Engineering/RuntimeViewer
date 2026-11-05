import Foundation
import Semantic

/// What a text or member search covered, and how much of it reached the
/// caller. Shared by both searches because the questions are the same.
public struct RuntimeInterfaceSearchSummary: Hashable, Codable, Sendable {
    /// Real total, counted past `resultLimit`.
    public let totalMatchCount: Int
    /// The images whose corpus the search read, in the order it read them.
    public let scannedImagePaths: [String]
    public let scannedObjectCount: Int
    /// `true` when more hits exist than were collected.
    public let isTruncated: Bool
    /// Indexed images with no corpus yet (pending, building or failed), so
    /// the UI can say what the search did not see. Only the images the query
    /// covers count: every indexed image, or those of its `imagePaths`.
    public let unbuiltIndexedImagePaths: [String]
    /// Set when the search stopped before reading everything it covers.
    /// What it delivered until then is correct, and its counts stand for what
    /// it read. `nil` for a search that read everything.
    public let stopReason: RuntimeInterfaceSearchStopReason?
    /// Hits in Objective-C protocol copies that read exactly like a copy the
    /// search already reported hits in — the same declaration, carried by
    /// another image. Neither collected nor part of `totalMatchCount`; the
    /// UI can say how many were folded into the copy it shows.
    public let omittedRepeatedMatchCount: Int

    public var scannedImageCount: Int {
        scannedImagePaths.count
    }

    public init(totalMatchCount: Int, scannedImagePaths: [String], scannedObjectCount: Int, isTruncated: Bool, unbuiltIndexedImagePaths: [String], stopReason: RuntimeInterfaceSearchStopReason? = nil, omittedRepeatedMatchCount: Int = 0) {
        self.totalMatchCount = totalMatchCount
        self.scannedImagePaths = scannedImagePaths
        self.scannedObjectCount = scannedObjectCount
        self.isTruncated = isTruncated
        self.unbuiltIndexedImagePaths = unbuiltIndexedImagePaths
        self.stopReason = stopReason
        self.omittedRepeatedMatchCount = omittedRepeatedMatchCount
    }
}
