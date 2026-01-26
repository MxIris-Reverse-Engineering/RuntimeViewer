public import Foundation
import MetaCodable
public import Semantic

/// Configuration for runtime interface transformers.
///
/// This structure aggregates all transformer settings and provides
/// methods to apply transformations to semantic strings.
@Codable
public struct TransformerConfiguration: Sendable, Equatable, Hashable {
    /// Whether transformers are enabled.
    @Default(ifMissing: false)
    public var isEnabled: Bool

    /// Custom type replacement rules.
    @Default(ifMissing: [])
    public var customTypeReplacements: [CTypeReplacement]

    /// Whether to use predefined stdint.h replacements.
    @Default(ifMissing: false)
    public var useStdintReplacements: Bool

    /// Creates a new transformer configuration.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether transformers are enabled.
    ///   - customTypeReplacements: Custom replacement rules.
    ///   - useStdintReplacements: Whether to use stdint.h replacements.
    public init(
        isEnabled: Bool = false,
        customTypeReplacements: [CTypeReplacement] = [],
        useStdintReplacements: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.customTypeReplacements = customTypeReplacements
        self.useStdintReplacements = useStdintReplacements
    }

    /// Returns all active replacement rules.
    ///
    /// This combines custom replacements with predefined stdint.h replacements
    /// if enabled, ensuring custom rules take precedence.
    public var activeReplacements: [CTypeReplacement] {
        var replacements = customTypeReplacements.filter { $0.isEnabled }

        if useStdintReplacements {
            // Get stdint replacements that don't conflict with custom ones
            let customPatterns = Set(replacements.map(\.pattern))
            let stdintReplacements = CTypeReplacement.stdintReplacements
                .filter { !customPatterns.contains($0.pattern) }
            replacements.append(contentsOf: stdintReplacements)
        }

        return replacements
    }

    /// Applies all enabled transformations to the given semantic string.
    ///
    /// - Parameters:
    ///   - interface: The semantic string to transform.
    ///   - context: The transformation context.
    /// - Returns: The transformed semantic string.
    public func apply(to interface: SemanticString, context: TransformContext) -> SemanticString {
        guard isEnabled else {
            return interface
        }

        let replacements = activeReplacements
        guard !replacements.isEmpty else {
            return interface
        }

        let transformer = CTypeReplacementTransformer(
            replacements: replacements,
            scope: .global,
            isEnabled: true
        )

        return transformer.transform(interface, context: context)
    }
}

// MARK: - Convenience Methods

extension TransformerConfiguration {
    /// A configuration with all transformers disabled.
    public static var disabled: TransformerConfiguration {
        TransformerConfiguration()
    }

    /// A configuration with stdint.h replacements enabled.
    public static var stdintEnabled: TransformerConfiguration {
        TransformerConfiguration(
            isEnabled: true,
            useStdintReplacements: true
        )
    }

    /// Adds a custom type replacement rule.
    ///
    /// - Parameter replacement: The replacement rule to add.
    /// - Returns: A new configuration with the rule added.
    public func adding(_ replacement: CTypeReplacement) -> TransformerConfiguration {
        var copy = self
        copy.customTypeReplacements.append(replacement)
        return copy
    }

    /// Removes a custom type replacement rule by ID.
    ///
    /// - Parameter id: The ID of the rule to remove.
    /// - Returns: A new configuration with the rule removed.
    public func removing(id: UUID) -> TransformerConfiguration {
        var copy = self
        copy.customTypeReplacements.removeAll { $0.id == id }
        return copy
    }

    /// Updates a custom type replacement rule.
    ///
    /// - Parameter replacement: The updated replacement rule.
    /// - Returns: A new configuration with the rule updated.
    public func updating(_ replacement: CTypeReplacement) -> TransformerConfiguration {
        var copy = self
        if let index = copy.customTypeReplacements.firstIndex(where: { $0.id == replacement.id }) {
            copy.customTypeReplacements[index] = replacement
        }
        return copy
    }
}
