import Foundation
import MetaCodable
import Semantic

// MARK: - Swift Enum Layout Transformer Module

extension Transformer {
    /// Customizes Swift enum layout comment format using token templates.
    ///
    /// Supports two template levels:
    /// - `template`: Controls the strategy header comment (e.g., "Multi-Payload (Spare Bits)")
    /// - `caseTemplate`: Controls the per-case header comment (e.g., "Case 0 (0x00) - Payload Case 0:")
    ///
    /// Memory change details per case are kept unchanged.
    @Codable
    public struct SwiftEnumLayout: Module {
        public typealias Parameter = Token
        public typealias Output = String

        public static let displayName = "Enum Layout Comment"

        @Default(ifMissing: false)
        public var isEnabled: Bool

        @Default(ifMissing: Templates.strategyOnly)
        public var template: String

        @Default(ifMissing: CaseTemplates.standard)
        public var caseTemplate: String

        @Default(ifMissing: false)
        public var useHexadecimal: Bool

        @Default(ifMissing: MemoryOffsetTemplates.standard)
        public var memoryOffsetTemplate: String

        public init(
            isEnabled: Bool = false,
            template: String = Templates.strategyOnly,
            caseTemplate: String = CaseTemplates.standard,
            useHexadecimal: Bool = false,
            memoryOffsetTemplate: String = MemoryOffsetTemplates.standard
        ) {
            self.isEnabled = isEnabled
            self.template = template
            self.caseTemplate = caseTemplate
            self.useHexadecimal = useHexadecimal
            self.memoryOffsetTemplate = memoryOffsetTemplate
        }

        /// Renders the strategy header template with actual enum layout values.
        public func transform(_ input: Input) -> String {
            var result = template
            result = result.replacingOccurrences(of: Token.strategy.placeholder, with: input.strategy)
            result = result.replacingOccurrences(of: Token.bitsNeededForTag.placeholder, with: formatNumeric(input.bitsNeededForTag))
            result = result.replacingOccurrences(of: Token.bitsAvailableForPayload.placeholder, with: formatNumeric(input.bitsAvailableForPayload))
            result = result.replacingOccurrences(of: Token.numTags.placeholder, with: formatNumeric(input.numTags))
            result = result.replacingOccurrences(of: Token.totalCases.placeholder, with: formatNumeric(input.totalCases))
            result = result.replacingOccurrences(of: Token.payloadCaseCount.placeholder, with: formatNumeric(input.payloadCaseCount))
            result = result.replacingOccurrences(of: Token.emptyCaseCount.placeholder, with: formatNumeric(input.emptyCaseCount))
            result = result.replacingOccurrences(of: Token.tagRegionRange.placeholder, with: input.tagRegionRange)
            result = result.replacingOccurrences(of: Token.tagRegionBitCount.placeholder, with: formatNumeric(input.tagRegionBitCount))
            result = result.replacingOccurrences(of: Token.tagRegionBytesHex.placeholder, with: input.tagRegionBytesHex)
            result = result.replacingOccurrences(of: Token.payloadRegionRange.placeholder, with: input.payloadRegionRange)
            result = result.replacingOccurrences(of: Token.payloadRegionBitCount.placeholder, with: formatNumeric(input.payloadRegionBitCount))
            result = result.replacingOccurrences(of: Token.payloadRegionBytesHex.placeholder, with: input.payloadRegionBytesHex)
            return result
        }

        /// Renders the per-case template with actual case values.
        public func transformCase(_ input: CaseInput) -> String {
            var result = caseTemplate
            result = result.replacingOccurrences(of: CaseToken.caseIndex.placeholder, with: formatNumeric(input.caseIndex))
            result = result.replacingOccurrences(of: CaseToken.caseHex.placeholder, with: String(format: "0x%02X", input.caseIndex))
            result = result.replacingOccurrences(of: CaseToken.caseName.placeholder, with: input.caseName)
            result = result.replacingOccurrences(of: CaseToken.tagValue.placeholder, with: formatNumeric(input.tagValue))
            result = result.replacingOccurrences(of: CaseToken.payloadValue.placeholder, with: formatNumeric(input.payloadValue))
            result = result.replacingOccurrences(of: CaseToken.tagHex.placeholder, with: input.tagHex)
            result = result.replacingOccurrences(of: CaseToken.payloadHex.placeholder, with: input.payloadHex)
            result = result.replacingOccurrences(of: CaseToken.tagValueBinary.placeholder, with: input.tagValueBinary)
            result = result.replacingOccurrences(of: CaseToken.payloadValueBinary.placeholder, with: input.payloadValueBinary)
            result = result.replacingOccurrences(of: CaseToken.caseType.placeholder, with: input.caseType)
            result = result.replacingOccurrences(of: CaseToken.memoryChangeCount.placeholder, with: formatNumeric(input.memoryChangeCount))
            result = result.replacingOccurrences(of: CaseToken.memoryChangesDetail.placeholder, with: input.memoryChangesDetail)
            return result
        }

        /// Renders the per-memory-offset template with actual offset values.
        public func transformMemoryOffset(_ input: MemoryOffsetInput) -> String {
            var result = memoryOffsetTemplate
            result = result.replacingOccurrences(of: MemoryOffsetToken.offset.placeholder, with: formatNumeric(input.offset))
            result = result.replacingOccurrences(of: MemoryOffsetToken.offsetHex.placeholder, with: String(format: "0x%02X", input.offset))
            result = result.replacingOccurrences(of: MemoryOffsetToken.value.placeholder, with: formatNumeric(Int(input.value)))
            result = result.replacingOccurrences(of: MemoryOffsetToken.valueHex.placeholder, with: String(format: "0x%02X", input.value))
            result = result.replacingOccurrences(of: MemoryOffsetToken.valueBinaryRaw.placeholder, with: input.valueBinaryRaw)
            result = result.replacingOccurrences(of: MemoryOffsetToken.valueBinary.placeholder, with: input.valueBinary)
            result = result.replacingOccurrences(of: MemoryOffsetToken.valueBinaryPaddedRaw.placeholder, with: input.valueBinaryPaddedRaw)
            result = result.replacingOccurrences(of: MemoryOffsetToken.valueBinaryPadded.placeholder, with: input.valueBinaryPadded)
            return result
        }

        private func formatNumeric(_ value: Int) -> String {
            useHexadecimal ? "0x\(String(value, radix: 16, uppercase: true))" : String(value)
        }

        /// Checks if the strategy template contains a specific token.
        public func contains(_ token: Token) -> Bool {
            template.contains(token.placeholder)
        }

        /// Checks if the case template contains a specific case token.
        public func containsCase(_ token: CaseToken) -> Bool {
            caseTemplate.contains(token.placeholder)
        }

        /// Checks if the memory offset template contains a specific token.
        public func containsMemoryOffset(_ token: MemoryOffsetToken) -> Bool {
            memoryOffsetTemplate.contains(token.placeholder)
        }
    }
}

// MARK: - Input (Strategy Header)

extension Transformer.SwiftEnumLayout {
    /// Input for strategy header transformation.
    public struct Input: Sendable {
        public let strategy: String
        public let bitsNeededForTag: Int
        public let bitsAvailableForPayload: Int
        public let numTags: Int
        public let totalCases: Int
        public let payloadCaseCount: Int
        public let emptyCaseCount: Int
        public let tagRegionRange: String
        public let tagRegionBitCount: Int
        public let tagRegionBytesHex: String
        public let payloadRegionRange: String
        public let payloadRegionBitCount: Int
        public let payloadRegionBytesHex: String

        public init(
            strategy: String,
            bitsNeededForTag: Int,
            bitsAvailableForPayload: Int,
            numTags: Int,
            totalCases: Int = 0,
            payloadCaseCount: Int = 0,
            emptyCaseCount: Int = 0,
            tagRegionRange: String = "N/A",
            tagRegionBitCount: Int = 0,
            tagRegionBytesHex: String = "N/A",
            payloadRegionRange: String = "N/A",
            payloadRegionBitCount: Int = 0,
            payloadRegionBytesHex: String = "N/A"
        ) {
            self.strategy = strategy
            self.bitsNeededForTag = bitsNeededForTag
            self.bitsAvailableForPayload = bitsAvailableForPayload
            self.numTags = numTags
            self.totalCases = totalCases
            self.payloadCaseCount = payloadCaseCount
            self.emptyCaseCount = emptyCaseCount
            self.tagRegionRange = tagRegionRange
            self.tagRegionBitCount = tagRegionBitCount
            self.tagRegionBytesHex = tagRegionBytesHex
            self.payloadRegionRange = payloadRegionRange
            self.payloadRegionBitCount = payloadRegionBitCount
            self.payloadRegionBytesHex = payloadRegionBytesHex
        }
    }
}

// MARK: - Case Input

extension Transformer.SwiftEnumLayout {
    /// Input for per-case transformation.
    public struct CaseInput: Sendable {
        public let caseIndex: Int
        public let caseName: String
        public let tagValue: Int
        public let payloadValue: Int
        public let tagHex: String
        public let payloadHex: String
        public let tagValueBinary: String
        public let payloadValueBinary: String
        public let caseType: String
        public let memoryChangeCount: Int
        public let memoryChangesDetail: String

        public init(
            caseIndex: Int,
            caseName: String,
            tagValue: Int,
            payloadValue: Int,
            tagHex: String = "0x00",
            payloadHex: String = "0x00",
            tagValueBinary: String = "0b0",
            payloadValueBinary: String = "0b0",
            caseType: String = "Unknown",
            memoryChangeCount: Int = 0,
            memoryChangesDetail: String = ""
        ) {
            self.caseIndex = caseIndex
            self.caseName = caseName
            self.tagValue = tagValue
            self.payloadValue = payloadValue
            self.tagHex = tagHex
            self.payloadHex = payloadHex
            self.tagValueBinary = tagValueBinary
            self.payloadValueBinary = payloadValueBinary
            self.caseType = caseType
            self.memoryChangeCount = memoryChangeCount
            self.memoryChangesDetail = memoryChangesDetail
        }
    }
}

// MARK: - Memory Offset Input

extension Transformer.SwiftEnumLayout {
    /// Input for per-memory-offset transformation.
    public struct MemoryOffsetInput: Sendable {
        public let offset: Int
        public let value: UInt8
        /// Binary string without prefix (e.g., "1")
        public let valueBinaryRaw: String
        /// Binary string with 0b prefix (e.g., "0b1")
        public let valueBinary: String
        /// Binary string padded to 8 digits without prefix (e.g., "00000001")
        public let valueBinaryPaddedRaw: String
        /// Binary string padded to 8 digits with 0b prefix (e.g., "0b00000001")
        public let valueBinaryPadded: String

        public init(
            offset: Int,
            value: UInt8
        ) {
            self.offset = offset
            self.value = value
            let binaryString = String(value, radix: 2)
            let paddedBinaryString = String(repeating: "0", count: 8 - binaryString.count) + binaryString
            self.valueBinaryRaw = binaryString
            self.valueBinary = "0b\(binaryString)"
            self.valueBinaryPaddedRaw = paddedBinaryString
            self.valueBinaryPadded = "0b\(paddedBinaryString)"
        }
    }
}

// MARK: - Token (Strategy Header)

extension Transformer.SwiftEnumLayout {
    /// Available tokens for strategy header templates.
    public enum Token: String, CaseIterable, Sendable {
        case strategy
        case bitsNeededForTag
        case bitsAvailableForPayload
        case numTags
        case totalCases
        case payloadCaseCount
        case emptyCaseCount
        case tagRegionRange
        case tagRegionBitCount
        case tagRegionBytesHex
        case payloadRegionRange
        case payloadRegionBitCount
        case payloadRegionBytesHex

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .strategy: "Strategy"
            case .bitsNeededForTag: "Bits Needed For Tag"
            case .bitsAvailableForPayload: "Bits Available For Payload"
            case .numTags: "Number of Tags"
            case .totalCases: "Total Cases"
            case .payloadCaseCount: "Payload Case Count"
            case .emptyCaseCount: "Empty Case Count"
            case .tagRegionRange: "Tag Region Range"
            case .tagRegionBitCount: "Tag Region Bit Count"
            case .tagRegionBytesHex: "Tag Region Bytes (Hex)"
            case .payloadRegionRange: "Payload Region Range"
            case .payloadRegionBitCount: "Payload Region Bit Count"
            case .payloadRegionBytesHex: "Payload Region Bytes (Hex)"
            }
        }
    }
}

// MARK: - Memory Offset Token

extension Transformer.SwiftEnumLayout {
    /// Available tokens for per-memory-offset templates.
    public enum MemoryOffsetToken: String, CaseIterable, Sendable {
        case offset
        case offsetHex
        case value
        case valueHex
        case valueBinaryRaw
        case valueBinary
        case valueBinaryPaddedRaw
        case valueBinaryPadded

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .offset: "Offset"
            case .offsetHex: "Offset (Hex)"
            case .value: "Value"
            case .valueHex: "Value (Hex)"
            case .valueBinaryRaw: "Value (Binary Raw)"
            case .valueBinary: "Value (Binary)"
            case .valueBinaryPaddedRaw: "Value (Binary Padded Raw)"
            case .valueBinaryPadded: "Value (Binary Padded)"
            }
        }
    }
}

// MARK: - Case Token

extension Transformer.SwiftEnumLayout {
    /// Available tokens for per-case templates.
    public enum CaseToken: String, CaseIterable, Sendable {
        case caseIndex
        case caseHex
        case caseName
        case tagValue
        case payloadValue
        case tagHex
        case payloadHex
        case tagValueBinary
        case payloadValueBinary
        case caseType
        case memoryChangeCount
        case memoryChangesDetail

        public var placeholder: String { "${\(rawValue)}" }
        public var displayName: String {
            switch self {
            case .caseIndex: "Case Index"
            case .caseHex: "Case Hex"
            case .caseName: "Case Name"
            case .tagValue: "Tag Value"
            case .payloadValue: "Payload Value"
            case .tagHex: "Tag Hex"
            case .payloadHex: "Payload Hex"
            case .tagValueBinary: "Tag Value (Binary)"
            case .payloadValueBinary: "Payload Value (Binary)"
            case .caseType: "Case Type"
            case .memoryChangeCount: "Memory Change Count"
            case .memoryChangesDetail: "Memory Changes Detail"
            }
        }
    }
}

// MARK: - Templates (Strategy Header)

extension Transformer.SwiftEnumLayout {
    public enum Templates {
        /// Standard style: "Multi-Payload (Spare Bits + Occupied Bits Overflow) (Tags: 3, Tag Bits: 2)"
        public static let standard = "${strategy} (Tags: ${numTags}, Tag Bits: ${bitsNeededForTag})"

        /// Verbose style: "Multi-Payload (Spare Bits + Occupied Bits Overflow) (Tags: 3, Tag Bits: 2, Payload Bits: 62)"
        public static let verbose = "${strategy} (Tags: ${numTags}, Tag Bits: ${bitsNeededForTag}, Payload Bits: ${bitsAvailableForPayload})"

        /// Strategy only: "Multi-Payload (Spare Bits + Occupied Bits Overflow)"
        public static let strategyOnly = "${strategy}"

        /// Compact style: "Tags: 3, Bits: 2"
        public static let compact = "Tags: ${numTags}, Bits: ${bitsNeededForTag}"

        /// Technical style with tag/payload/case counts
        public static let technical = "${strategy}\nTags: ${numTags} (${bitsNeededForTag}-bit), Payload: ${bitsAvailableForPayload}-bit, Cases: ${totalCases}"

        /// Region detail style showing tag and payload memory regions
        public static let regions = "${strategy}\nTag Region: ${tagRegionRange} (${tagRegionBitCount} bits)\nPayload Region: ${payloadRegionRange} (${payloadRegionBitCount} bits)"

        /// Summary style: strategy with case and tag counts
        public static let summary = "${strategy} — ${totalCases} cases, ${numTags} tags"

        /// Bits-focused style showing bit allocation
        public static let bits = "Tag: ${bitsNeededForTag} bits, Payload: ${bitsAvailableForPayload} bits (${numTags} tags)"

        /// Case breakdown style showing payload vs empty case counts
        public static let caseBreakdown = "${strategy} — ${payloadCaseCount} payload + ${emptyCaseCount} empty = ${totalCases} cases"

        /// Full detail style with regions and byte patterns
        public static let fullDetail = "${strategy}\nTags: ${numTags} (${bitsNeededForTag}-bit), Payload: ${bitsAvailableForPayload}-bit\nTag Region: ${tagRegionRange} (${tagRegionBitCount} bits) [${tagRegionBytesHex}]\nPayload Region: ${payloadRegionRange} (${payloadRegionBitCount} bits) [${payloadRegionBytesHex}]\nCases: ${payloadCaseCount} payload + ${emptyCaseCount} empty"

        public static let all: [(name: String, template: String)] = [
            ("Standard", standard),
            ("Verbose", verbose),
            ("Strategy Only", strategyOnly),
            ("Compact", compact),
            ("Technical", technical),
            ("Regions", regions),
            ("Summary", summary),
            ("Bits", bits),
            ("Case Breakdown", caseBreakdown),
            ("Full Detail", fullDetail),
        ]
    }
}

// MARK: - Memory Offset Templates

extension Transformer.SwiftEnumLayout {
    public enum MemoryOffsetTemplates {
        /// Standard style: "Memory Offset 0 (0x00) = 0x01 (Bin: 00000001)"
        public static let standard = "Memory Offset ${offset} (${offsetHex}) = ${valueHex} (Bin: ${valueBinaryPaddedRaw})"

        /// Compact style: "[0]=0x01"
        public static let compact = "[${offset}]=${valueHex}"

        /// Hex only style: "0x00: 0x01"
        public static let hexOnly = "${offsetHex}: ${valueHex}"

        /// Binary style: "Offset 0: 0b00000001"
        public static let binary = "Offset ${offset}: ${valueBinaryPadded}"

        /// Verbose style: "Offset 0 (0x00) = 1 (0x01, 0b00000001)"
        public static let verbose = "Offset ${offset} (${offsetHex}) = ${value} (${valueHex}, ${valueBinaryPadded})"

        /// Minimal style: "0: 0x01"
        public static let minimal = "${offset}: ${valueHex}"

        public static let all: [(name: String, template: String)] = [
            ("Standard", standard),
            ("Compact", compact),
            ("Hex Only", hexOnly),
            ("Binary", binary),
            ("Verbose", verbose),
            ("Minimal", minimal),
        ]
    }
}

// MARK: - Case Templates

extension Transformer.SwiftEnumLayout {
    public enum CaseTemplates {
        /// Standard style: "Case 0 (0x00) - Payload Case 0:\nTag: 0"
        public static let standard = "Case ${caseIndex} (${caseHex}) - ${caseName}:\nTag: ${tagValue}"

        /// Verbose style includes payload value: "Case 0 (0x00) - Payload Case 0:\nTag: 0, PayloadValue: 0"
        public static let verbose = "Case ${caseIndex} (${caseHex}) - ${caseName}:\nTag: ${tagValue}, PayloadValue: ${payloadValue}"

        /// Compact style: "[0] Payload Case 0 (tag: 0)"
        public static let compact = "[${caseIndex}] ${caseName} (tag: ${tagValue})"

        /// Index only: "Case 0: Tag 0"
        public static let indexOnly = "Case ${caseIndex}: Tag ${tagValue}"

        /// Hex-all style with tag and payload hex values
        public static let hexAll = "Case ${caseHex}: ${caseName} [tag=${tagHex}, payload=${payloadHex}]"

        /// Named style with case type and tag
        public static let named = "${caseName} (${caseType}, tag: ${tagValue})"

        /// Detailed style with all available information
        public static let detailed = "Case ${caseIndex} (${caseHex}) - ${caseName}:\nType: ${caseType}, Tag: ${tagValue} (${tagHex}), Payload: ${payloadValue} (${payloadHex})\nMemory Changes: ${memoryChangeCount} bytes"

        /// Memory-focused style showing byte change count
        public static let memory = "[${caseHex}] ${caseName} — ${memoryChangeCount} byte(s) changed"

        /// Binary style showing tag and payload in binary representation
        public static let binary = "Case ${caseIndex}: ${caseName}\nTag: ${tagValueBinary} (${tagHex}), Payload: ${payloadValueBinary} (${payloadHex})"

        /// Memory detail style with per-offset byte changes
        public static let memoryDetail = "Case ${caseIndex} (${caseHex}) - ${caseName} [${caseType}]:\nTag: ${tagValue} (${tagHex}), Payload: ${payloadValue} (${payloadHex})\n${memoryChangesDetail}"

        public static let all: [(name: String, template: String)] = [
            ("Standard", standard),
            ("Verbose", verbose),
            ("Compact", compact),
            ("Index Only", indexOnly),
            ("Hex All", hexAll),
            ("Named", named),
            ("Detailed", detailed),
            ("Memory", memory),
            ("Binary", binary),
            ("Memory Detail", memoryDetail),
        ]
    }
}
