import Foundation
import MetaCodable
import Semantic

// MARK: - Swift Member Address Transformer Module

extension Transformer {
    /// Customizes Swift member address comment format using token templates.
    ///
    /// Available tokens:
    /// - `${offset}` - Raw file offset value
    ///
    /// Example:
    /// ```swift
    /// var module = Transformer.SwiftMemberAddress()
    /// module.isEnabled = true
    /// module.template = "Address: ${offset}"  // "Address: 0x1234"
    /// ```
    @Codable
    public struct SwiftMemberAddress: Module {
        public typealias Parameter = Token
        public typealias Output = String

        public static let displayName = "Swift Member Address Comment"

        @Default(ifMissing: false)
        public var isEnabled: Bool

        @Default(ifMissing: Templates.standard)
        public var template: String

        @Default(ifMissing: true)
        public var useHexadecimal: Bool

        public init(isEnabled: Bool = false, template: String = Templates.standard, useHexadecimal: Bool = true) {
            self.isEnabled = isEnabled
            self.template = template
            self.useHexadecimal = useHexadecimal
        }

        /// Renders the template with actual address offset.
        public func transform(_ input: Input) -> String {
            template
                .replacingOccurrences(of: Token.offset.placeholder, with: formatValue(input.offset))
        }

        private func formatValue(_ value: Int) -> String {
            useHexadecimal ? "0x\(String(value, radix: 16, uppercase: true))" : String(value)
        }

        /// Checks if the template contains a specific token.
        public func contains(_ token: Token) -> Bool {
            template.contains(token.placeholder)
        }
    }
}

// MARK: - Input

extension Transformer.SwiftMemberAddress {
    /// Input for member address transformation.
    public struct Input: Sendable {
        public let offset: Int

        public init(offset: Int) {
            self.offset = offset
        }
    }
}

// MARK: - Token

extension Transformer.SwiftMemberAddress {
    /// Available tokens for member address templates.
    public enum Token: String, CaseIterable, Sendable {
        case offset

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .offset: "Offset"
            }
        }
    }
}

// MARK: - Templates

extension Transformer.SwiftMemberAddress {
    public enum Templates {
        /// Default style: "Address: 0x1234"
        public static let standard = "Address: ${offset}"

        /// Compact style: "0x1234"
        public static let compact = "${offset}"

        /// Labeled style: "addr: 0x1234"
        public static let labeled = "addr: ${offset}"

        public static let all: [(name: String, template: String)] = [
            ("Standard", standard),
            ("Compact", compact),
            ("Labeled", labeled),
        ]
    }
}
