public import Foundation
import MetaCodable
public import Semantic

// MARK: - C Type Transformer Module

extension Transformer {
    /// Replaces C primitive types with custom types.
    ///
    /// Example:
    /// ```swift
    /// var module = Transformer.CType()
    /// module.isEnabled = true
    /// module.replacements[.double] = "CGFloat"
    /// module.replacements[.longLong] = "NSInteger"
    /// ```
    @Codable
    public struct CType: Module {
        public typealias Parameter = Pattern
        public typealias Input = SemanticString
        public typealias Output = SemanticString

        public static let displayName = "C Type Replacement"

        @Default(ifMissing: false)
        public var isEnabled: Bool

        @Default(ifMissing: [:])
        public var replacements: [Pattern: String]

        public init(isEnabled: Bool = false, replacements: [Pattern: String] = [:]) {
            self.isEnabled = isEnabled
            self.replacements = replacements
        }

        public func transform(_ input: SemanticString) -> SemanticString {
            let sorted = sortedReplacements
            guard !sorted.isEmpty else { return input }

            let components = input.components
            guard !components.isEmpty else { return input }

            var result: [AtomicComponent] = []
            var index = 0

            while index < components.count {
                if let (replacement, consumed) = match(in: components, at: index, patterns: sorted) {
                    result.append(AtomicComponent(string: replacement, type: .keyword))
                    index += consumed
                } else {
                    result.append(components[index])
                    index += 1
                }
            }

            return SemanticString(components: result)
        }

        // Sorted by pattern length (longest first)
        private var sortedReplacements: [(Pattern, String)] {
            replacements
                .filter { !$0.value.isEmpty }
                .sorted { $0.key.keywords.count > $1.key.keywords.count }
                .map { ($0.key, $0.value) }
        }

        private func match(
            in components: [AtomicComponent],
            at startIndex: Int,
            patterns: [(Pattern, String)]
        ) -> (String, Int)? {
            for (pattern, replacement) in patterns {
                if let consumed = matchKeywords(pattern.keywords, in: components, at: startIndex) {
                    return (replacement, consumed)
                }
            }
            return nil
        }

        private func matchKeywords(
            _ keywords: [String],
            in components: [AtomicComponent],
            at startIndex: Int
        ) -> Int? {
            guard !keywords.isEmpty else { return nil }

            var ci = startIndex
            var ki = 0
            var consumed = 0

            while ki < keywords.count && ci < components.count {
                let c = components[ci]

                // Skip whitespace
                if c.type == .standard && c.string.allSatisfy(\.isWhitespace) {
                    ci += 1
                    consumed += 1
                    continue
                }

                guard c.type == .keyword, c.string == keywords[ki] else { return nil }

                ki += 1
                ci += 1
                consumed += 1
            }

            return ki == keywords.count ? consumed : nil
        }
    }
}

// MARK: - Pattern

extension Transformer.CType {
    /// C primitive type patterns.
    public enum Pattern: String, CaseIterable, Codable, Sendable, Hashable {
        case char
        case uchar
        case short
        case ushort
        case int
        case uint
        case long
        case ulong
        case longLong
        case ulongLong
        case float
        case double
        case longDouble

        public var displayName: String {
            switch self {
            case .char: "char"
            case .uchar: "unsigned char"
            case .short: "short"
            case .ushort: "unsigned short"
            case .int: "int"
            case .uint: "unsigned int"
            case .long: "long"
            case .ulong: "unsigned long"
            case .longLong: "long long"
            case .ulongLong: "unsigned long long"
            case .float: "float"
            case .double: "double"
            case .longDouble: "long double"
            }
        }

        var keywords: [String] {
            switch self {
            case .char: ["char"]
            case .uchar: ["unsigned", "char"]
            case .short: ["short"]
            case .ushort: ["unsigned", "short"]
            case .int: ["int"]
            case .uint: ["unsigned", "int"]
            case .long: ["long"]
            case .ulong: ["unsigned", "long"]
            case .longLong: ["long", "long"]
            case .ulongLong: ["unsigned", "long", "long"]
            case .float: ["float"]
            case .double: ["double"]
            case .longDouble: ["long", "double"]
            }
        }
    }
}

// MARK: - Presets

extension Transformer.CType {
    public enum Presets {
        public static let stdint: [Pattern: String] = [
            .uchar: "uint8_t",
            .ushort: "uint16_t",
            .uint: "uint32_t",
            .ulongLong: "uint64_t",
            .longLong: "int64_t",
            .short: "int16_t",
        ]

        public static let foundation: [Pattern: String] = [
            .double: "CGFloat",
            .float: "CGFloat",
            .long: "NSInteger",
            .ulong: "NSUInteger",
            .longLong: "NSInteger",
            .ulongLong: "NSUInteger",
        ]
    }
}
