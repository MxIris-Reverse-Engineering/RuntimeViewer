public import Foundation
import MetaCodable
public import Semantic

/// Configuration for all runtime interface transformer modules.
///
/// This structure aggregates all transformer module configurations and provides
/// methods to apply transformations to semantic strings.
///
/// Users configure individual modules through this unified configuration:
/// - `cType`: C type replacement (double → CGFloat, etc.)
/// - `swiftFieldOffset`: Swift field offset comment format
@Codable
public struct TransformerConfiguration: Sendable, Equatable, Hashable {
    /// C type replacement transformer configuration.
    @Default(ifMissing: CTypeTransformerConfig())
    public var cType: CTypeTransformerConfig

    /// Swift field offset comment transformer configuration.
    @Default(ifMissing: SwiftFieldOffsetTransformerConfig())
    public var swiftFieldOffset: SwiftFieldOffsetTransformerConfig

    /// Creates a new transformer configuration with default settings.
    public init() {
        self.cType = CTypeTransformerConfig()
        self.swiftFieldOffset = SwiftFieldOffsetTransformerConfig()
    }

    /// Creates a new transformer configuration with the specified module configs.
    public init(
        cType: CTypeTransformerConfig = CTypeTransformerConfig(),
        swiftFieldOffset: SwiftFieldOffsetTransformerConfig = SwiftFieldOffsetTransformerConfig()
    ) {
        self.cType = cType
        self.swiftFieldOffset = swiftFieldOffset
    }

    /// Whether any transformer module is enabled.
    public var hasEnabledModules: Bool {
        cType.isEnabled || swiftFieldOffset.isEnabled
    }

    /// Applies all enabled transformations to the given semantic string.
    ///
    /// - Parameters:
    ///   - interface: The semantic string to transform.
    ///   - context: The transformation context.
    /// - Returns: The transformed semantic string.
    public func apply(to interface: SemanticString, context: TransformContext) -> SemanticString {
        var result = interface

        // Apply C type transformer if enabled
        if cType.isEnabled {
            result = applyCTypeTransformer(to: result, context: context)
        }

        // Note: Swift field offset transformer is applied during generation,
        // not as a post-process, since it needs access to offset values.

        return result
    }

    /// Applies C type replacements to the semantic string.
    private func applyCTypeTransformer(to interface: SemanticString, context: TransformContext) -> SemanticString {
        let sortedPatterns = cType.sortedPatterns
        guard !sortedPatterns.isEmpty else { return interface }

        let components = interface.components
        guard !components.isEmpty else { return interface }

        var result: [AtomicComponent] = []
        var index = 0

        while index < components.count {
            if let (replacement, consumedCount) = findCTypeMatch(
                in: components,
                startingAt: index,
                patterns: sortedPatterns
            ) {
                result.append(AtomicComponent(string: replacement, type: .keyword))
                index += consumedCount
            } else {
                result.append(components[index])
                index += 1
            }
        }

        return SemanticString(components: result)
    }

    /// Finds a matching C type pattern starting at the given index.
    private func findCTypeMatch(
        in components: [AtomicComponent],
        startingAt startIndex: Int,
        patterns: [(CTypeTransformerConfig.Pattern, String)]
    ) -> (String, Int)? {
        for (pattern, replacement) in patterns {
            if let consumedCount = matchPattern(pattern.patternString, in: components, startingAt: startIndex) {
                return (replacement, consumedCount)
            }
        }
        return nil
    }

    /// Matches a pattern string against components using sliding window.
    private func matchPattern(
        _ patternString: String,
        in components: [AtomicComponent],
        startingAt startIndex: Int
    ) -> Int? {
        let keywords = patternString.split(separator: " ").map(String.init)
        guard !keywords.isEmpty else { return nil }

        var componentIndex = startIndex
        var keywordIndex = 0
        var consumedCount = 0

        while keywordIndex < keywords.count && componentIndex < components.count {
            let component = components[componentIndex]

            // Skip whitespace
            if component.type == .standard && component.string.allSatisfy(\.isWhitespace) {
                componentIndex += 1
                consumedCount += 1
                continue
            }

            // Must be keyword type
            guard component.type == .keyword else { return nil }

            // Check match
            if component.string == keywords[keywordIndex] {
                keywordIndex += 1
                componentIndex += 1
                consumedCount += 1
            } else {
                return nil
            }
        }

        return keywordIndex == keywords.count ? consumedCount : nil
    }
}

// MARK: - Convenience Presets

extension TransformerConfiguration {
    /// A configuration with all modules disabled.
    public static var disabled: TransformerConfiguration {
        TransformerConfiguration()
    }

    /// A configuration with stdint.h style C type replacements enabled.
    public static var stdintPreset: TransformerConfiguration {
        TransformerConfiguration(
            cType: CTypeTransformerConfig(
                isEnabled: true,
                replacements: CTypeTransformerConfig.stdintPreset
            )
        )
    }

    /// A configuration with Foundation style C type replacements enabled.
    public static var foundationPreset: TransformerConfiguration {
        TransformerConfiguration(
            cType: CTypeTransformerConfig(
                isEnabled: true,
                replacements: CTypeTransformerConfig.foundationPreset
            )
        )
    }
}
