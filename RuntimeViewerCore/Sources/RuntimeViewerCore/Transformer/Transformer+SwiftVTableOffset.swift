import Foundation
import MetaCodable
import Semantic

// MARK: - Swift VTable Offset Transformer Module

extension Transformer {
    /// Customizes Swift VTable Offset comment format using token templates.
    ///
    /// Available tokens:
    /// - `${slotOffset}` - VTable slot offset
    /// - `${label}` - Optional label (e.g. getter/setter)
    ///
    /// Example:
    /// ```swift
    /// var module = Transformer.SwiftVTableOffset()
    /// module.isEnabled = true
    /// module.template = "VTable Offset: ${slotOffset}"         // "VTable Offset: 42"
    /// module.labeledTemplate = "VTable Offset (${label}): ${slotOffset}"  // "VTable Offset (getter): 42"
    /// ```
    @Codable
    public struct SwiftVTableOffset: Module {
        public typealias Parameter = Token
        public typealias Output = String

        public static let displayName = "Swift VTable Offset Comment"

        @Default(ifMissing: false)
        public var isEnabled: Bool

        @Default(ifMissing: Templates.standard)
        public var template: String

        @Default(ifMissing: Templates.standardLabeled)
        public var labeledTemplate: String

        @Default(ifMissing: false)
        public var useHexadecimal: Bool

        public init(
            isEnabled: Bool = false,
            template: String = Templates.standard,
            labeledTemplate: String = Templates.standardLabeled,
            useHexadecimal: Bool = false
        ) {
            self.isEnabled = isEnabled
            self.template = template
            self.labeledTemplate = labeledTemplate
            self.useHexadecimal = useHexadecimal
        }

        /// Renders the template with actual VTable Offset values.
        ///
        /// Uses `labeledTemplate` when `label` is non-nil, otherwise uses `template`.
        public func transform(_ input: Input) -> String {
            let activeTemplate = input.label != nil ? labeledTemplate : template
            return activeTemplate
                .replacingOccurrences(of: Token.slotOffset.placeholder, with: formatValue(input.slotOffset))
                .replacingOccurrences(of: Token.label.placeholder, with: input.label ?? "")
        }

        private func formatValue(_ value: Int) -> String {
            useHexadecimal ? "0x\(String(value, radix: 16, uppercase: true))" : String(value)
        }

        /// Checks if the template contains a specific token.
        public func contains(_ token: Token) -> Bool {
            template.contains(token.placeholder) || labeledTemplate.contains(token.placeholder)
        }
    }
}

// MARK: - Input

extension Transformer.SwiftVTableOffset {
    /// Input for VTable Offset transformation.
    public struct Input: Sendable {
        public let slotOffset: Int
        public let label: String?

        public init(slotOffset: Int, label: String?) {
            self.slotOffset = slotOffset
            self.label = label
        }
    }
}

// MARK: - Token

extension Transformer.SwiftVTableOffset {
    /// Available tokens for VTable Offset templates.
    public enum Token: String, CaseIterable, Sendable {
        case slotOffset
        case label

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .slotOffset: "Slot Offset"
            case .label: "Label"
            }
        }
    }
}

// MARK: - Templates

extension Transformer.SwiftVTableOffset {
    public enum Templates {
        /// Default style: "VTable Offset: 42"
        public static let standard = "VTable Offset: ${slotOffset}"

        /// Default labeled style: "VTable Offset (getter): 42"
        public static let standardLabeled = "VTable Offset (${label}): ${slotOffset}"

        /// Compact style: "VTable[42]"
        public static let compact = "VTable[${slotOffset}]"

        /// Compact labeled style: "VTable[42] (getter)"
        public static let compactLabeled = "VTable[${slotOffset}] (${label})"

        /// Offset only: "42"
        public static let offsetOnly = "${slotOffset}"

        public static let all: [(name: String, template: String)] = [
            ("Standard", standard),
            ("Compact", compact),
            ("Offset Only", offsetOnly),
        ]

        public static let allLabeled: [(name: String, template: String)] = [
            ("Standard", standardLabeled),
            ("Compact", compactLabeled),
            ("Offset Only", offsetOnly),
        ]
    }
}
