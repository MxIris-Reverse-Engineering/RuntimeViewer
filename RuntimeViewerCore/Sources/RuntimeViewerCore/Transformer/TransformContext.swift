public import Foundation

/// Context information passed to transformers during transformation.
///
/// This structure provides transformers with metadata about the current
/// transformation operation, such as the source image path.
public struct TransformContext: Sendable {
    /// The path of the image being processed.
    public let imagePath: String

    /// The name of the runtime object being transformed.
    public let objectName: String

    /// Creates a new transformation context.
    ///
    /// - Parameters:
    ///   - imagePath: The path of the image being processed.
    ///   - objectName: The name of the runtime object being transformed.
    public init(imagePath: String, objectName: String) {
        self.imagePath = imagePath
        self.objectName = objectName
    }
}
