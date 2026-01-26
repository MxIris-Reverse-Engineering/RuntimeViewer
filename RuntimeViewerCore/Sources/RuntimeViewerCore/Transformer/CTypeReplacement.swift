public import Foundation
import MetaCodable

/// A configuration for replacing C/ObjC types with alternative representations.
///
/// This structure defines a single type replacement rule, specifying the
/// pattern to match and the replacement string to use.
///
/// Example:
/// ```swift
/// let replacement = CTypeReplacement(
///     pattern: "unsigned int",
///     replacement: "uint32_t",
///     scope: .global
/// )
/// ```
@Codable
public struct CTypeReplacement: Sendable, Equatable, Hashable, Identifiable {
    /// Unique identifier for this replacement rule.
    @Default(ifMissing: UUID())
    public var id: UUID

    /// The scope in which this replacement should be applied.
    @Default(ifMissing: TransformScope.global)
    public var scope: TransformScope

    /// The pattern to match (e.g., "unsigned int").
    ///
    /// This should be the exact sequence of keywords to match.
    /// Multi-keyword patterns like "unsigned long long" are supported.
    public var pattern: String

    /// The replacement string (e.g., "uint32_t").
    public var replacement: String

    /// Whether this replacement rule is currently enabled.
    @Default(ifMissing: true)
    public var isEnabled: Bool

    /// Creates a new C type replacement rule.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (auto-generated if not provided).
    ///   - pattern: The pattern to match.
    ///   - replacement: The replacement string.
    ///   - scope: The scope for this replacement (defaults to global).
    ///   - isEnabled: Whether the rule is enabled (defaults to true).
    public init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String,
        scope: TransformScope = .global,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.scope = scope
        self.isEnabled = isEnabled
    }
}

// MARK: - Predefined Replacements

extension CTypeReplacement {
    /// Predefined stdint.h type replacements.
    ///
    /// These replacements convert traditional C integer types to their
    /// fixed-width equivalents from `<stdint.h>`.
    public static var stdintReplacements: [CTypeReplacement] {
        [
            // Unsigned types
            CTypeReplacement(pattern: "unsigned long long", replacement: "uint64_t"),
            CTypeReplacement(pattern: "unsigned long", replacement: "unsigned long"), // Platform-dependent, keep as-is
            CTypeReplacement(pattern: "unsigned int", replacement: "uint32_t"),
            CTypeReplacement(pattern: "unsigned short", replacement: "uint16_t"),
            CTypeReplacement(pattern: "unsigned char", replacement: "uint8_t"),
            // Signed types
            CTypeReplacement(pattern: "long long", replacement: "int64_t"),
            CTypeReplacement(pattern: "short", replacement: "int16_t"),
            CTypeReplacement(pattern: "signed char", replacement: "int8_t"),
        ]
    }
}
