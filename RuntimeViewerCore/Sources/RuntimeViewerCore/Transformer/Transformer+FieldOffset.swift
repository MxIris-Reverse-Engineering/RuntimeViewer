public import Foundation
import MetaCodable
public import Semantic

// MARK: - Swift Field Offset Transformer Module

extension Transformer {
    /// Customizes Swift field offset comment format using token templates.
    ///
    /// Available tokens:
    /// - `${startOffset}` - Field start offset
    /// - `${endOffset}` - Field end offset
    ///
    /// Example:
    /// ```swift
    /// var module = Transformer.FieldOffset()
    /// module.isEnabled = true
    /// module.template = "${startOffset} ..< ${endOffset}"  // "0 ..< 8"
    /// module.template = "offset: ${startOffset}"           // "offset: 0"
    /// ```
    @Codable
    public struct FieldOffset: Module {
        public typealias Parameter = Token
        public typealias Output = String

        public static let displayName = "Field Offset Format"

        @Default(ifMissing: false)
        public var isEnabled: Bool

        @Default(ifMissing: Templates.range)
        public var template: String

        public init(isEnabled: Bool = false, template: String = Templates.range) {
            self.isEnabled = isEnabled
            self.template = template
        }

        /// Renders the template with actual offset values.
        public func transform(_ input: Input) -> String {
            template
                .replacingOccurrences(of: Token.startOffset.placeholder, with: String(input.startOffset))
                .replacingOccurrences(of: Token.endOffset.placeholder, with: String(input.endOffset))
        }

        /// Checks if the template contains a specific token.
        public func contains(_ token: Token) -> Bool {
            template.contains(token.placeholder)
        }
    }
}

// MARK: - Input

extension Transformer.FieldOffset {
    /// Input for field offset transformation.
    public struct Input: Sendable {
        public let startOffset: Int
        public let endOffset: Int

        public init(startOffset: Int, endOffset: Int) {
            self.startOffset = startOffset
            self.endOffset = endOffset
        }
    }
}

// MARK: - Token

extension Transformer.FieldOffset {
    /// Available tokens for field offset templates.
    public enum Token: String, CaseIterable, Sendable {
        case startOffset
        case endOffset

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .startOffset: "Start Offset"
            case .endOffset: "End Offset"
            }
        }
    }
}

// MARK: - Templates

extension Transformer.FieldOffset {
    public enum Templates {
        /// Range style: "0 ..< 8"
        public static let range = "${startOffset} ..< ${endOffset}"

        /// Labeled style: "offset: 0"
        public static let labeled = "offset: ${startOffset}"

        /// Interval style: "[0, 8)"
        public static let interval = "[${startOffset}, ${endOffset})"

        /// Start only: "0"
        public static let startOnly = "${startOffset}"

        public static let all: [(name: String, template: String)] = [
            ("Range", range),
            ("Labeled", labeled),
            ("Interval", interval),
            ("Start Only", startOnly),
        ]
    }
}
