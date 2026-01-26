public import Foundation
public import Semantic

/// A transformer that replaces C/ObjC type keywords with alternative representations.
///
/// This transformer uses a sliding window approach to match multi-keyword type
/// patterns like "unsigned long long" and replace them with their equivalents.
///
/// Example:
/// ```swift
/// let replacements = [
///     CTypeReplacement(pattern: "unsigned int", replacement: "uint32_t")
/// ]
/// let transformer = CTypeReplacementTransformer(replacements: replacements)
/// let transformed = transformer.transform(interface, context: context)
/// ```
public struct CTypeReplacementTransformer: RuntimeInterfaceTransformer, Sendable {
    /// Unique identifier for this transformer.
    public let identifier: String = "c-type-replacement"

    /// The scope for this transformer.
    public let scope: TransformScope

    /// Whether this transformer is enabled.
    public let isEnabled: Bool

    /// The replacement rules to apply.
    public let replacements: [CTypeReplacement]

    /// Pre-computed pattern information for efficient matching.
    private let patternInfos: [PatternInfo]

    /// Information about a parsed pattern for efficient matching.
    private struct PatternInfo: Sendable {
        let replacement: CTypeReplacement
        let keywords: [String]
    }

    /// Creates a new C type replacement transformer.
    ///
    /// - Parameters:
    ///   - replacements: The replacement rules to apply.
    ///   - scope: The scope for this transformer (defaults to global).
    ///   - isEnabled: Whether the transformer is enabled (defaults to true).
    public init(
        replacements: [CTypeReplacement],
        scope: TransformScope = .global,
        isEnabled: Bool = true
    ) {
        self.replacements = replacements
        self.scope = scope
        self.isEnabled = isEnabled

        // Pre-parse patterns into keywords for efficient matching
        // Sort by keyword count (descending) to match longer patterns first
        self.patternInfos = replacements
            .filter { $0.isEnabled }
            .map { replacement in
                PatternInfo(
                    replacement: replacement,
                    keywords: replacement.pattern
                        .split(separator: " ")
                        .map(String.init)
                )
            }
            .sorted { $0.keywords.count > $1.keywords.count }
    }

    /// Transforms the given semantic string by applying type replacements.
    ///
    /// The transformer scans through keyword components and uses a sliding
    /// window to match multi-keyword patterns. When a match is found, it
    /// replaces the matched keywords with the replacement string.
    ///
    /// - Parameters:
    ///   - interface: The semantic string to transform.
    ///   - context: The transformation context.
    /// - Returns: The transformed semantic string.
    public func transform(_ interface: SemanticString, context: TransformContext) -> SemanticString {
        guard isEnabled, !patternInfos.isEmpty else {
            return interface
        }

        let components = interface.components
        guard !components.isEmpty else {
            return interface
        }

        var result: [AtomicComponent] = []
        var index = 0

        while index < components.count {
            // Try to match a pattern starting at this index
            if let (match, consumedCount) = findMatch(in: components, startingAt: index, context: context) {
                // Add the replacement component
                result.append(AtomicComponent(string: match.replacement.replacement, type: .keyword))
                index += consumedCount
            } else {
                // No match, copy the component as-is
                result.append(components[index])
                index += 1
            }
        }

        return SemanticString(components: result)
    }

    /// Attempts to find a matching pattern starting at the given index.
    ///
    /// - Parameters:
    ///   - components: The components to search in.
    ///   - startIndex: The starting index.
    ///   - context: The transformation context.
    /// - Returns: A tuple of (matched pattern info, number of components consumed), or nil if no match.
    private func findMatch(
        in components: [AtomicComponent],
        startingAt startIndex: Int,
        context: TransformContext
    ) -> (PatternInfo, Int)? {
        for patternInfo in patternInfos {
            // Check if the pattern's scope matches
            guard patternInfo.replacement.scope.matches(imagePath: context.imagePath) else {
                continue
            }

            // Try to match this pattern
            if let consumedCount = matchPattern(patternInfo, in: components, startingAt: startIndex) {
                return (patternInfo, consumedCount)
            }
        }
        return nil
    }

    /// Attempts to match a specific pattern starting at the given index.
    ///
    /// This method uses a sliding window approach to match keyword sequences,
    /// skipping over whitespace components between keywords.
    ///
    /// - Parameters:
    ///   - patternInfo: The pattern to match.
    ///   - components: The components to search in.
    ///   - startIndex: The starting index.
    /// - Returns: The number of components consumed if matched, or nil if no match.
    private func matchPattern(
        _ patternInfo: PatternInfo,
        in components: [AtomicComponent],
        startingAt startIndex: Int
    ) -> Int? {
        let keywords = patternInfo.keywords
        guard !keywords.isEmpty else { return nil }

        var componentIndex = startIndex
        var keywordIndex = 0
        var consumedCount = 0

        while keywordIndex < keywords.count && componentIndex < components.count {
            let component = components[componentIndex]

            // Skip whitespace/standard components (spaces between keywords)
            if component.type == .standard && component.string.allSatisfy({ $0.isWhitespace }) {
                componentIndex += 1
                consumedCount += 1
                continue
            }

            // Check if this is a keyword component
            guard component.type == .keyword else {
                // Non-keyword, non-whitespace component - no match
                return nil
            }

            // Check if the keyword matches
            if component.string == keywords[keywordIndex] {
                keywordIndex += 1
                componentIndex += 1
                consumedCount += 1
            } else {
                // Keyword doesn't match
                return nil
            }
        }

        // Check if we matched all keywords
        if keywordIndex == keywords.count {
            return consumedCount
        }

        return nil
    }
}

// MARK: - Convenience Initializers

extension CTypeReplacementTransformer {
    /// Creates a transformer with the predefined stdint.h replacements.
    ///
    /// - Parameters:
    ///   - scope: The scope for the transformer (defaults to global).
    ///   - isEnabled: Whether the transformer is enabled (defaults to true).
    /// - Returns: A transformer configured with stdint.h replacements.
    public static func stdint(
        scope: TransformScope = .global,
        isEnabled: Bool = true
    ) -> CTypeReplacementTransformer {
        CTypeReplacementTransformer(
            replacements: CTypeReplacement.stdintReplacements,
            scope: scope,
            isEnabled: isEnabled
        )
    }
}
