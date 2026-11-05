import Foundation
import Semantic

/// What `RuntimeEngine.restoreInterfaceCorpora(for:transformer:)` read.
public struct RuntimeInterfaceCorpusRestoreResult: Hashable, Codable, Sendable {
    /// Keyed by the path as the serving process keeps it
    /// (`RuntimeEngine.canonicalImagePath(_:)`).
    public var restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage]

    public init(restoredImagesByImagePath: [String: RuntimeInterfaceCorpusRestoredImage]) {
        self.restoredImagesByImagePath = restoredImagesByImagePath
    }

    public static let empty = RuntimeInterfaceCorpusRestoreResult(restoredImagesByImagePath: [:])
}
