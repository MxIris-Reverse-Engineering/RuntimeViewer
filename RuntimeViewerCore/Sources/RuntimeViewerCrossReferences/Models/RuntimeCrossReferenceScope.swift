import Foundation
import RuntimeViewerCore

/// The images a query reads. Only images the engine has indexed — both their
/// Objective-C and their Swift section built: the ones opened in the sidebar
/// and the ones background indexing read — are ever scanned.
public enum RuntimeCrossReferenceScope: Hashable, Codable, Sendable {
    /// One image, which the engine must have indexed.
    case image(path: String)
    /// Every image the engine has indexed.
    case indexedImages
}
