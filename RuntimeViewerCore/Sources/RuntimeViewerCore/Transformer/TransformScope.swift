public import Foundation
import MetaCodable

/// Defines the scope in which a transformer should be applied.
///
/// Scopes allow fine-grained control over where transformations are applied,
/// enabling different behavior for different images or globally.
@Codable
public enum TransformScope: Sendable, Equatable, Hashable {
    /// Apply the transformation globally to all images.
    case global

    /// Apply the transformation only to a specific image.
    case imageOnly(imagePath: String)

    /// Checks if this scope matches the given image path.
    ///
    /// - Parameter imagePath: The image path to check against.
    /// - Returns: `true` if the transformation should be applied to the given image.
    public func matches(imagePath: String) -> Bool {
        switch self {
        case .global:
            return true
        case .imageOnly(let targetPath):
            return imagePath == targetPath
        }
    }
}
