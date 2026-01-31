import Foundation
import MetaCodable
import Semantic

// MARK: - Swift Type Layout Comment Transformer Module

extension Transformer {
    /// Customizes Swift type layout comment format using token templates.
    ///
    /// Available tokens:
    /// - `${size}` - Type size in bytes
    /// - `${stride}` - Type stride in bytes
    /// - `${alignment}` - Type alignment
    /// - `${extraInhabitantCount}` - Extra inhabitant count
    /// - `${isPOD}` - Whether the type is plain old data
    /// - `${isInlineStorage}` - Whether the type uses inline storage
    /// - `${isBitwiseTakable}` - Whether the type is bitwise takable
    /// - `${isBitwiseBorrowable}` - Whether the type is bitwise borrowable
    /// - `${isCopyable}` - Whether the type is copyable
    /// - `${hasEnumWitnesses}` - Whether the type has enum witnesses
    /// - `${isIncomplete}` - Whether the type layout is incomplete
    ///
    /// Example:
    /// ```swift
    /// var module = Transformer.SwiftTypeLayout()
    /// module.isEnabled = true
    /// module.template = "size: ${size}, stride: ${stride}, alignment: ${alignment}"
    /// ```
    @Codable
    public struct SwiftTypeLayout: Module {
        public typealias Parameter = Token
        public typealias Output = String

        public static let displayName = "Type Layout Comment"

        @Default(ifMissing: false)
        public var isEnabled: Bool

        @Default(ifMissing: Templates.standard)
        public var template: String

        @Default(ifMissing: false)
        public var useHexadecimal: Bool

        public init(isEnabled: Bool = false, template: String = Templates.standard, useHexadecimal: Bool = false) {
            self.isEnabled = isEnabled
            self.template = template
            self.useHexadecimal = useHexadecimal
        }

        /// Renders the template with actual type layout values.
        public func transform(_ input: Input) -> String {
            var result = template
            result = result.replacingOccurrences(of: Token.size.placeholder, with: formatNumeric(input.size))
            result = result.replacingOccurrences(of: Token.stride.placeholder, with: formatNumeric(input.stride))
            result = result.replacingOccurrences(of: Token.alignment.placeholder, with: formatNumeric(input.alignment))
            result = result.replacingOccurrences(of: Token.extraInhabitantCount.placeholder, with: formatNumeric(input.extraInhabitantCount))
            result = result.replacingOccurrences(of: Token.isPOD.placeholder, with: String(input.isPOD))
            result = result.replacingOccurrences(of: Token.isInlineStorage.placeholder, with: String(input.isInlineStorage))
            result = result.replacingOccurrences(of: Token.isBitwiseTakable.placeholder, with: String(input.isBitwiseTakable))
            result = result.replacingOccurrences(of: Token.isBitwiseBorrowable.placeholder, with: String(input.isBitwiseBorrowable))
            result = result.replacingOccurrences(of: Token.isCopyable.placeholder, with: String(input.isCopyable))
            result = result.replacingOccurrences(of: Token.hasEnumWitnesses.placeholder, with: String(input.hasEnumWitnesses))
            result = result.replacingOccurrences(of: Token.isIncomplete.placeholder, with: String(input.isIncomplete))
            return result
        }

        private func formatNumeric(_ value: Int) -> String {
            useHexadecimal ? "0x\(String(value, radix: 16))" : String(value)
        }

        /// Checks if the template contains a specific token.
        public func contains(_ token: Token) -> Bool {
            template.contains(token.placeholder)
        }
    }
}

// MARK: - Input

extension Transformer.SwiftTypeLayout {
    /// Input for type layout transformation.
    public struct Input: Sendable {
        public let size: Int
        public let stride: Int
        public let alignment: Int
        public let extraInhabitantCount: Int
        public let isPOD: Bool
        public let isInlineStorage: Bool
        public let isBitwiseTakable: Bool
        public let isBitwiseBorrowable: Bool
        public let isCopyable: Bool
        public let hasEnumWitnesses: Bool
        public let isIncomplete: Bool

        public init(
            size: Int,
            stride: Int,
            alignment: Int,
            extraInhabitantCount: Int,
            isPOD: Bool,
            isInlineStorage: Bool,
            isBitwiseTakable: Bool,
            isBitwiseBorrowable: Bool,
            isCopyable: Bool,
            hasEnumWitnesses: Bool,
            isIncomplete: Bool
        ) {
            self.size = size
            self.stride = stride
            self.alignment = alignment
            self.extraInhabitantCount = extraInhabitantCount
            self.isPOD = isPOD
            self.isInlineStorage = isInlineStorage
            self.isBitwiseTakable = isBitwiseTakable
            self.isBitwiseBorrowable = isBitwiseBorrowable
            self.isCopyable = isCopyable
            self.hasEnumWitnesses = hasEnumWitnesses
            self.isIncomplete = isIncomplete
        }
    }
}

// MARK: - Token

extension Transformer.SwiftTypeLayout {
    /// Available tokens for type layout templates.
    public enum Token: String, CaseIterable, Sendable {
        case size
        case stride
        case alignment
        case extraInhabitantCount
        case isPOD
        case isInlineStorage
        case isBitwiseTakable
        case isBitwiseBorrowable
        case isCopyable
        case hasEnumWitnesses
        case isIncomplete

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .size: "Size"
            case .stride: "Stride"
            case .alignment: "Alignment"
            case .extraInhabitantCount: "Extra Inhabitant Count"
            case .isPOD: "Is POD"
            case .isInlineStorage: "Is Inline Storage"
            case .isBitwiseTakable: "Is Bitwise Takable"
            case .isBitwiseBorrowable: "Is Bitwise Borrowable"
            case .isCopyable: "Is Copyable"
            case .hasEnumWitnesses: "Has Enum Witnesses"
            case .isIncomplete: "Is Incomplete"
            }
        }
    }
}

// MARK: - Templates

extension Transformer.SwiftTypeLayout {
    public enum Templates {
        /// Standard style: "TypeLayout(size: 8, stride: 8, alignment: 8, extraInhabitantCount: 0)"
        public static let standard = "TypeLayout(size: ${size}, stride: ${stride}, alignment: ${alignment}, extraInhabitantCount: ${extraInhabitantCount})"

        /// Verbose style includes flags: "TypeLayout(size: 8, stride: 8, alignment: 8, extraInhabitantCount: 0, isPOD: true, isInlineStorage: true, isBitwiseTakable: true, isBitwiseBorrowable: true, isCopyable: true, hasEnumWitnesses: false, isIncomplete: false)"
        public static let verbose = "TypeLayout(size: ${size}, stride: ${stride}, alignment: ${alignment}, extraInhabitantCount: ${extraInhabitantCount}, isPOD: ${isPOD}, isInlineStorage: ${isInlineStorage}, isBitwiseTakable: ${isBitwiseTakable}, isBitwiseBorrowable: ${isBitwiseBorrowable}, isCopyable: ${isCopyable}, hasEnumWitnesses: ${hasEnumWitnesses}, isIncomplete: ${isIncomplete})"

        /// Compact style: "size: 8, stride: 8, align: 8"
        public static let compact = "size: ${size}, stride: ${stride}, align: ${alignment}"

        /// Size only: "8 bytes"
        public static let sizeOnly = "${size} bytes"

        public static let all: [(name: String, template: String)] = [
            ("Standard", standard),
            ("Verbose", verbose),
            ("Compact", compact),
            ("Size Only", sizeOnly),
        ]
    }
}
