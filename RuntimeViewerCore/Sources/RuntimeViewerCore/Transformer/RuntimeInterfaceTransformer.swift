public import Foundation
public import Semantic

/// A protocol for transforming runtime interface semantic strings.
///
/// Transformers can modify the semantic string representation of runtime
/// interfaces, enabling customizations like type replacements, formatting
/// changes, or annotation injection.
///
/// Example:
/// ```swift
/// struct MyTransformer: RuntimeInterfaceTransformer {
///     var identifier: String { "my-transformer" }
///     var scope: TransformScope { .global }
///     var isEnabled: Bool { true }
///
///     func transform(_ interface: SemanticString, context: TransformContext) -> SemanticString {
///         // Transform and return modified interface
///         return interface
///     }
/// }
/// ```
public protocol RuntimeInterfaceTransformer: Sendable {
    /// A unique identifier for this transformer.
    var identifier: String { get }

    /// The scope in which this transformer should be applied.
    var scope: TransformScope { get }

    /// Whether this transformer is currently enabled.
    var isEnabled: Bool { get }

    /// Transforms the given semantic string interface.
    ///
    /// - Parameters:
    ///   - interface: The semantic string to transform.
    ///   - context: Context information about the transformation.
    /// - Returns: The transformed semantic string.
    func transform(_ interface: SemanticString, context: TransformContext) -> SemanticString
}

extension RuntimeInterfaceTransformer {
    /// Checks if this transformer should be applied for the given context.
    ///
    /// - Parameter context: The transformation context.
    /// - Returns: `true` if the transformer should be applied.
    public func shouldApply(for context: TransformContext) -> Bool {
        isEnabled && scope.matches(imagePath: context.imagePath)
    }
}
