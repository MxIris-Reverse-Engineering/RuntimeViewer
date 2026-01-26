import Foundation
import MetaCodable

// MARK: - Transformer Module Protocol

/// A predefined transformer module that can be configured by users.
///
/// Transformer modules are system-provided and cannot be created by users.
/// Users can only enable/disable them and configure their output format.
public protocol TransformerModule: Sendable, Identifiable {
    /// The unique identifier for this module type.
    static var moduleID: String { get }

    /// Human-readable name for display in Settings UI.
    static var displayName: String { get }

    /// Description of what this transformer does.
    static var moduleDescription: String { get }

    /// Whether this module is currently enabled.
    var isEnabled: Bool { get set }
}

// MARK: - C Type Transformer

/// Transformer for replacing C/ObjC primitive types.
///
/// Provides predefined patterns (char, unsigned, long, int, double, etc.)
/// that users can map to custom replacement strings.
///
/// Example:
/// ```swift
/// var config = CTypeTransformerConfig()
/// config.replacements[.double] = "CGFloat"
/// config.replacements[.longLong] = "NSInteger"
/// ```
@Codable
public struct CTypeTransformerConfig: TransformerModule, Equatable, Hashable {
    public static let moduleID = "c-type"
    public static let displayName = "C Type Replacement"
    public static let moduleDescription = "Replace C primitive types with custom types (e.g., double → CGFloat)"

    public var id: String { Self.moduleID }

    /// Predefined C type patterns that can be replaced.
    public enum Pattern: String, CaseIterable, Codable, Sendable {
        case char
        case uchar = "unsigned char"
        case short
        case ushort = "unsigned short"
        case int
        case uint = "unsigned int"
        case long
        case ulong = "unsigned long"
        case longLong = "long long"
        case ulongLong = "unsigned long long"
        case float
        case double
        case longDouble = "long double"

        /// The pattern string to match in the interface.
        public var patternString: String { rawValue }

        /// Human-readable display name.
        public var displayName: String {
            switch self {
            case .char: return "char"
            case .uchar: return "unsigned char"
            case .short: return "short"
            case .ushort: return "unsigned short"
            case .int: return "int"
            case .uint: return "unsigned int"
            case .long: return "long"
            case .ulong: return "unsigned long"
            case .longLong: return "long long"
            case .ulongLong: return "unsigned long long"
            case .float: return "float"
            case .double: return "double"
            case .longDouble: return "long double"
            }
        }
    }

    /// Whether this transformer is enabled.
    @Default(ifMissing: false)
    public var isEnabled: Bool

    /// User-configured replacements for each pattern.
    /// Key: Pattern, Value: Replacement string (nil means use original)
    @Default(ifMissing: [:])
    public var replacements: [Pattern: String]

    public init(isEnabled: Bool = false, replacements: [Pattern: String] = [:]) {
        self.isEnabled = isEnabled
        self.replacements = replacements
    }

    /// Gets the replacement for a pattern, or nil if not configured.
    public func replacement(for pattern: Pattern) -> String? {
        replacements[pattern]
    }

    /// Returns patterns sorted by length (longest first) for proper matching.
    public var sortedPatterns: [(Pattern, String)] {
        replacements
            .filter { $0.value.isEmpty == false }
            .map { ($0.key, $0.value) }
            .sorted { $0.0.patternString.count > $1.0.patternString.count }
    }
}

// MARK: - Predefined Replacement Sets

extension CTypeTransformerConfig {
    /// Stdint.h style replacements (uint32_t, int64_t, etc.)
    public static var stdintPreset: [Pattern: String] {
        [
            .uchar: "uint8_t",
            .ushort: "uint16_t",
            .uint: "uint32_t",
            .ulongLong: "uint64_t",
            .longLong: "int64_t",
            .short: "int16_t",
        ]
    }

    /// CoreGraphics/Foundation style replacements (CGFloat, NSInteger, etc.)
    public static var foundationPreset: [Pattern: String] {
        [
            .double: "CGFloat",
            .float: "CGFloat",
            .long: "NSInteger",
            .ulong: "NSUInteger",
            .longLong: "NSInteger",
            .ulongLong: "NSUInteger",
        ]
    }
}

// MARK: - Swift Field Offset Comment Transformer

/// Transformer for customizing Swift field offset comment format.
///
/// Provides tokens `${startOffset}` and `${endOffset}` that users can
/// arrange in their preferred format.
///
/// Example templates:
/// - `"${startOffset} ..< ${endOffset}"` → "0 ..< 8"
/// - `"offset: ${startOffset}"` → "offset: 0"
/// - `"[${startOffset}, ${endOffset})"` → "[0, 8)"
@Codable
public struct SwiftFieldOffsetTransformerConfig: TransformerModule, Equatable, Hashable {
    public static let moduleID = "swift-field-offset"
    public static let displayName = "Swift Field Offset Format"
    public static let moduleDescription = "Customize the format of field offset comments in Swift interfaces"

    public var id: String { Self.moduleID }

    /// Available tokens for the template.
    public enum Token: String, CaseIterable, Sendable {
        case startOffset
        case endOffset

        public var placeholder: String { "${\(rawValue)}" }
    }

    /// Whether this transformer is enabled.
    @Default(ifMissing: false)
    public var isEnabled: Bool

    /// The template string with token placeholders.
    /// Default: "${startOffset} ..< ${endOffset}"
    @Default(ifMissing: "${startOffset} ..< ${endOffset}")
    public var template: String

    public init(isEnabled: Bool = false, template: String = "${startOffset} ..< ${endOffset}") {
        self.isEnabled = isEnabled
        self.template = template
    }

    /// Renders the template with the given offset values.
    public func render(startOffset: Int, endOffset: Int) -> String {
        template
            .replacingOccurrences(of: Token.startOffset.placeholder, with: String(startOffset))
            .replacingOccurrences(of: Token.endOffset.placeholder, with: String(endOffset))
    }

    /// Checks if the template contains a specific token.
    public func containsToken(_ token: Token) -> Bool {
        template.contains(token.placeholder)
    }
}

// MARK: - Preset Templates

extension SwiftFieldOffsetTransformerConfig {
    /// Range style: "0 ..< 8"
    public static let rangeTemplate = "${startOffset} ..< ${endOffset}"

    /// Labeled style: "offset: 0"
    public static let labeledTemplate = "offset: ${startOffset}"

    /// Interval style: "[0, 8)"
    public static let intervalTemplate = "[${startOffset}, ${endOffset})"

    /// Size style: "size: 8" (requires computation)
    public static let startOnlyTemplate = "${startOffset}"
}
