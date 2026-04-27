import Testing
import Foundation
import RuntimeViewerCore

// MARK: - Transformer.Configuration Tests

@Suite("Transformer.Configuration")
struct TransformerConfigurationTests {
    @Test("default configuration has no modules enabled")
    func defaultNoModulesEnabled() {
        let config = Transformer.Configuration.default
        #expect(config.hasEnabledModules == false)
        #expect(config.objc.cType.isEnabled == false)
        #expect(config.objc.ivarOffset.isEnabled == false)
        #expect(config.swift.swiftFieldOffset.isEnabled == false)
        #expect(config.swift.swiftTypeLayout.isEnabled == false)
        #expect(config.swift.swiftEnumLayout.isEnabled == false)
    }

    @Test("hasEnabledModules returns true when CType is enabled")
    func hasEnabledModulesCType() {
        var config = Transformer.Configuration.default
        config.objc.cType.isEnabled = true
        #expect(config.hasEnabledModules == true)
    }

    @Test("hasEnabledModules returns true when ObjCIvarOffset is enabled")
    func hasEnabledModulesObjCIvarOffset() {
        var config = Transformer.Configuration.default
        config.objc.ivarOffset.isEnabled = true
        #expect(config.hasEnabledModules == true)
    }

    @Test("hasEnabledModules returns true when SwiftFieldOffset is enabled")
    func hasEnabledModulesFieldOffset() {
        var config = Transformer.Configuration.default
        config.swift.swiftFieldOffset.isEnabled = true
        #expect(config.hasEnabledModules == true)
    }

    @Test("hasEnabledModules returns true when SwiftTypeLayout is enabled")
    func hasEnabledModulesTypeLayout() {
        var config = Transformer.Configuration.default
        config.swift.swiftTypeLayout.isEnabled = true
        #expect(config.hasEnabledModules == true)
    }

    @Test("hasEnabledModules returns true when SwiftEnumLayout is enabled")
    func hasEnabledModulesEnumLayout() {
        var config = Transformer.Configuration.default
        config.swift.swiftEnumLayout.isEnabled = true
        #expect(config.hasEnabledModules == true)
    }

    @Test("Codable round-trip")
    func codable() throws {
        var config = Transformer.Configuration.default
        config.objc.cType.isEnabled = true
        config.objc.cType.replacements = [.double: "CGFloat"]
        config.objc.ivarOffset.isEnabled = true
        config.objc.ivarOffset.template = "ivar: ${offset}"
        config.swift.swiftFieldOffset.isEnabled = true
        config.swift.swiftFieldOffset.template = "offset: ${startOffset}"

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Transformer.Configuration.self, from: data)
        #expect(decoded == config)
    }

    @Test("Equatable conformance")
    func equatable() {
        let a = Transformer.Configuration.default
        let b = Transformer.Configuration.default
        #expect(a == b)

        var c = Transformer.Configuration.default
        c.objc.cType.isEnabled = true
        #expect(a != c)
    }
}

// MARK: - CType Tests

@Suite("Transformer.CType")
struct TransformerCTypeTests {
    @Test("displayName")
    func displayName() {
        #expect(Transformer.CType.displayName == "C Type Replacement")
    }

    @Test("default init has isEnabled false and empty replacements")
    func defaultInit() {
        let ctype = Transformer.CType()
        #expect(ctype.isEnabled == false)
        #expect(ctype.replacements.isEmpty)
    }

    @Test("custom init sets fields")
    func customInit() {
        let ctype = Transformer.CType(isEnabled: true, replacements: [.int: "int32_t"])
        #expect(ctype.isEnabled == true)
        #expect(ctype.replacements[.int] == "int32_t")
    }

    // MARK: - Pattern

    @Test("Pattern displayNames", arguments: [
        (Transformer.CType.Pattern.char, "char"),
        (.uchar, "unsigned char"),
        (.short, "short"),
        (.ushort, "unsigned short"),
        (.int, "int"),
        (.uint, "unsigned int"),
        (.long, "long"),
        (.ulong, "unsigned long"),
        (.longLong, "long long"),
        (.ulongLong, "unsigned long long"),
        (.float, "float"),
        (.double, "double"),
        (.longDouble, "long double"),
    ] as [(Transformer.CType.Pattern, String)])
    func patternDisplayNames(pattern: Transformer.CType.Pattern, expected: String) {
        #expect(pattern.displayName == expected)
    }

    @Test("Pattern allCases has 13 patterns")
    func patternAllCases() {
        #expect(Transformer.CType.Pattern.allCases.count == 13)
    }

    @Test("Pattern rawValue round-trip", arguments: Transformer.CType.Pattern.allCases)
    func patternRawValueRoundTrip(pattern: Transformer.CType.Pattern) {
        let rawValue = pattern.rawValue
        let decoded = Transformer.CType.Pattern(rawValue: rawValue)
        #expect(decoded == pattern)
    }

    // MARK: - Presets

    @Test("stdint preset maps integer types")
    func stdintPreset() {
        let preset = Transformer.CType.Presets.stdint
        #expect(preset[.char] == "int8_t")
        #expect(preset[.uchar] == "uint8_t")
        #expect(preset[.int] == "int32_t")
        #expect(preset[.uint] == "uint32_t")
        #expect(preset[.long] == "int64_t")
        #expect(preset[.ulong] == "uint64_t")
    }

    @Test("foundation preset maps Foundation types")
    func foundationPreset() {
        let preset = Transformer.CType.Presets.foundation
        #expect(preset[.double] == "CGFloat")
        #expect(preset[.long] == "NSInteger")
        #expect(preset[.ulong] == "NSUInteger")
    }

    @Test("mixed preset combines stdint and foundation")
    func mixedPreset() {
        let preset = Transformer.CType.Presets.mixed
        #expect(preset[.char] == "int8_t")
        #expect(preset[.double] == "CGFloat")
        #expect(preset[.long] == "NSInteger")
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.CType(isEnabled: true, replacements: [.int: "int32_t", .double: "CGFloat"])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.CType.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - ObjCIvarOffset Tests

@Suite("Transformer.ObjCIvarOffset")
struct TransformerObjCIvarOffsetTests {
    @Test("displayName")
    func displayName() {
        #expect(Transformer.ObjCIvarOffset.displayName == "ObjC Ivar Offset Comment")
    }

    @Test("default init")
    func defaultInit() {
        let module = Transformer.ObjCIvarOffset()
        #expect(module.isEnabled == false)
        #expect(module.template == Transformer.ObjCIvarOffset.Templates.standard)
        #expect(module.useHexadecimal == true)
    }

    @Test("transform with standard template and hex")
    func transformStandardHex() {
        let module = Transformer.ObjCIvarOffset(isEnabled: true, template: Transformer.ObjCIvarOffset.Templates.standard, useHexadecimal: true)
        let result = module.transform(.init(offset: 32))
        #expect(result == "offset: 0x20")
    }

    @Test("transform with standard template and decimal")
    func transformStandardDecimal() {
        let module = Transformer.ObjCIvarOffset(isEnabled: true, template: Transformer.ObjCIvarOffset.Templates.standard, useHexadecimal: false)
        let result = module.transform(.init(offset: 32))
        #expect(result == "offset: 32")
    }

    @Test("contains checks token presence in template")
    func containsToken() {
        let module = Transformer.ObjCIvarOffset(template: Transformer.ObjCIvarOffset.Templates.standard)
        #expect(module.contains(.offset) == true)

        let staticModule = Transformer.ObjCIvarOffset(template: "offset")
        #expect(staticModule.contains(.offset) == false)
    }

    @Test("Token placeholder")
    func tokenPlaceholder() {
        #expect(Transformer.ObjCIvarOffset.Token.offset.placeholder == "${offset}")
    }

    @Test("Token displayName")
    func tokenDisplayName() {
        #expect(Transformer.ObjCIvarOffset.Token.offset.displayName == "Offset")
    }

    @Test("Templates.all has 3 entries")
    func templatesAll() {
        #expect(Transformer.ObjCIvarOffset.Templates.all.count == 3)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.ObjCIvarOffset(isEnabled: true, template: "custom: ${offset}", useHexadecimal: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.ObjCIvarOffset.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - SwiftFieldOffset Tests

@Suite("Transformer.SwiftFieldOffset")
struct TransformerSwiftFieldOffsetTests {
    @Test("displayName")
    func displayName() {
        #expect(Transformer.SwiftFieldOffset.displayName == "Swift Field Offset Comment")
    }

    @Test("default init")
    func defaultInit() {
        let module = Transformer.SwiftFieldOffset()
        #expect(module.isEnabled == false)
        #expect(module.template == Transformer.SwiftFieldOffset.Templates.standard)
        #expect(module.useHexadecimal == true)
    }

    // MARK: - transform

    @Test("transform with standard template and hex")
    func transformStandardHex() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.standard, useHexadecimal: true)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 8, endOffset: 16)
        let result = module.transform(input)
        #expect(result == "Field Offset: 0x8")
    }

    @Test("transform with standard template and decimal")
    func transformStandardDecimal() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.standard, useHexadecimal: false)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 8, endOffset: 16)
        let result = module.transform(input)
        #expect(result == "Field Offset: 8")
    }

    @Test("transform with range template")
    func transformRange() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.range, useHexadecimal: false)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 0, endOffset: 8)
        let result = module.transform(input)
        #expect(result == "0 ..< 8")
    }

    @Test("transform with nil endOffset shows ?")
    func transformNilEndOffset() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.range, useHexadecimal: false)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 16, endOffset: nil)
        let result = module.transform(input)
        #expect(result == "16 ..< ?")
    }

    @Test("transform with labeled template")
    func transformLabeled() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.labeled, useHexadecimal: false)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 0, endOffset: 8)
        let result = module.transform(input)
        #expect(result == "offset: 0")
    }

    @Test("transform with interval template")
    func transformInterval() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.interval, useHexadecimal: false)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 0, endOffset: 8)
        let result = module.transform(input)
        #expect(result == "[0, 8)")
    }

    @Test("transform with startOnly template")
    func transformStartOnly() {
        let module = Transformer.SwiftFieldOffset(isEnabled: true, template: Transformer.SwiftFieldOffset.Templates.startOnly, useHexadecimal: true)
        let input = Transformer.SwiftFieldOffset.Input(startOffset: 255, endOffset: nil)
        let result = module.transform(input)
        #expect(result == "0xFF")
    }

    // MARK: - contains

    @Test("contains checks token presence in template")
    func containsToken() {
        let module = Transformer.SwiftFieldOffset(template: Transformer.SwiftFieldOffset.Templates.standard)
        #expect(module.contains(.startOffset) == true)
        #expect(module.contains(.endOffset) == false)

        let rangeModule = Transformer.SwiftFieldOffset(template: Transformer.SwiftFieldOffset.Templates.range)
        #expect(rangeModule.contains(.startOffset) == true)
        #expect(rangeModule.contains(.endOffset) == true)
    }

    // MARK: - Token

    @Test("Token placeholders")
    func tokenPlaceholders() {
        #expect(Transformer.SwiftFieldOffset.Token.startOffset.placeholder == "${startOffset}")
        #expect(Transformer.SwiftFieldOffset.Token.endOffset.placeholder == "${endOffset}")
    }

    @Test("Token displayNames")
    func tokenDisplayNames() {
        #expect(Transformer.SwiftFieldOffset.Token.startOffset.displayName == "Start Offset")
        #expect(Transformer.SwiftFieldOffset.Token.endOffset.displayName == "End Offset")
    }

    @Test("Token allCases has 2 tokens")
    func tokenAllCases() {
        #expect(Transformer.SwiftFieldOffset.Token.allCases.count == 2)
    }

    // MARK: - Templates

    @Test("Templates.all has 5 entries")
    func templatesAll() {
        #expect(Transformer.SwiftFieldOffset.Templates.all.count == 5)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.SwiftFieldOffset(isEnabled: true, template: "custom: ${startOffset}", useHexadecimal: false)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.SwiftFieldOffset.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - SwiftTypeLayout Tests

@Suite("Transformer.SwiftTypeLayout")
struct TransformerSwiftTypeLayoutTests {
    @Test("displayName")
    func displayName() {
        #expect(Transformer.SwiftTypeLayout.displayName == "Type Layout Comment")
    }

    @Test("default init")
    func defaultInit() {
        let module = Transformer.SwiftTypeLayout()
        #expect(module.isEnabled == false)
        #expect(module.template == Transformer.SwiftTypeLayout.Templates.standard)
        #expect(module.useHexadecimal == false)
    }

    // MARK: - transform

    @Test("transform with standard template")
    func transformStandard() {
        let module = Transformer.SwiftTypeLayout(isEnabled: true)
        let input = Transformer.SwiftTypeLayout.Input(
            size: 8, stride: 8, alignment: 8,
            extraInhabitantCount: 0,
            isPOD: true, isInlineStorage: true,
            isBitwiseTakable: true, isBitwiseBorrowable: true,
            isCopyable: true, hasEnumWitnesses: false, isIncomplete: false
        )
        let result = module.transform(input)
        #expect(result.contains("size: 8"))
        #expect(result.contains("stride: 8"))
        #expect(result.contains("alignment: 8"))
        #expect(result.contains("extraInhabitantCount: 0"))
    }

    @Test("transform with compact template")
    func transformCompact() {
        let module = Transformer.SwiftTypeLayout(isEnabled: true, template: Transformer.SwiftTypeLayout.Templates.compact)
        let input = Transformer.SwiftTypeLayout.Input(
            size: 16, stride: 16, alignment: 8,
            extraInhabitantCount: 0,
            isPOD: false, isInlineStorage: false,
            isBitwiseTakable: true, isBitwiseBorrowable: true,
            isCopyable: true, hasEnumWitnesses: false, isIncomplete: false
        )
        let result = module.transform(input)
        #expect(result == "size: 16, stride: 16, align: 8")
    }

    @Test("transform with sizeOnly template")
    func transformSizeOnly() {
        let module = Transformer.SwiftTypeLayout(isEnabled: true, template: Transformer.SwiftTypeLayout.Templates.sizeOnly)
        let input = Transformer.SwiftTypeLayout.Input(
            size: 24, stride: 24, alignment: 8,
            extraInhabitantCount: 0,
            isPOD: true, isInlineStorage: true,
            isBitwiseTakable: true, isBitwiseBorrowable: true,
            isCopyable: true, hasEnumWitnesses: false, isIncomplete: false
        )
        let result = module.transform(input)
        #expect(result == "24 bytes")
    }

    @Test("transform with hex formatting")
    func transformHex() {
        let module = Transformer.SwiftTypeLayout(isEnabled: true, template: "${size}", useHexadecimal: true)
        let input = Transformer.SwiftTypeLayout.Input(
            size: 255, stride: 256, alignment: 8,
            extraInhabitantCount: 0,
            isPOD: true, isInlineStorage: true,
            isBitwiseTakable: true, isBitwiseBorrowable: true,
            isCopyable: true, hasEnumWitnesses: false, isIncomplete: false
        )
        let result = module.transform(input)
        #expect(result == "0xFF")
    }

    @Test("transform with verbose template includes boolean flags")
    func transformVerbose() {
        let module = Transformer.SwiftTypeLayout(isEnabled: true, template: Transformer.SwiftTypeLayout.Templates.verbose)
        let input = Transformer.SwiftTypeLayout.Input(
            size: 8, stride: 8, alignment: 8,
            extraInhabitantCount: 0,
            isPOD: true, isInlineStorage: false,
            isBitwiseTakable: true, isBitwiseBorrowable: false,
            isCopyable: true, hasEnumWitnesses: false, isIncomplete: false
        )
        let result = module.transform(input)
        #expect(result.contains("isPOD: true"))
        #expect(result.contains("isInlineStorage: false"))
        #expect(result.contains("isBitwiseBorrowable: false"))
    }

    // MARK: - contains

    @Test("contains checks token presence")
    func containsToken() {
        let module = Transformer.SwiftTypeLayout(template: Transformer.SwiftTypeLayout.Templates.compact)
        #expect(module.contains(.size) == true)
        #expect(module.contains(.stride) == true)
        #expect(module.contains(.alignment) == true)
        #expect(module.contains(.isPOD) == false)
    }

    // MARK: - Token

    @Test("Token allCases has 11 tokens")
    func tokenAllCases() {
        #expect(Transformer.SwiftTypeLayout.Token.allCases.count == 11)
    }

    @Test("Token placeholders follow pattern", arguments: Transformer.SwiftTypeLayout.Token.allCases)
    func tokenPlaceholderPattern(token: Transformer.SwiftTypeLayout.Token) {
        #expect(token.placeholder.hasPrefix("${"))
        #expect(token.placeholder.hasSuffix("}"))
        #expect(token.placeholder.contains(token.rawValue))
    }

    @Test("Token displayNames are non-empty", arguments: Transformer.SwiftTypeLayout.Token.allCases)
    func tokenDisplayNamesNonEmpty(token: Transformer.SwiftTypeLayout.Token) {
        #expect(!token.displayName.isEmpty)
    }

    // MARK: - Templates

    @Test("Templates.all has 5 entries")
    func templatesAll() {
        #expect(Transformer.SwiftTypeLayout.Templates.all.count == 5)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.SwiftTypeLayout(isEnabled: true, template: "custom", useHexadecimal: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.SwiftTypeLayout.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - SwiftEnumLayout Tests

@Suite("Transformer.SwiftEnumLayout")
struct TransformerSwiftEnumLayoutTests {
    @Test("displayName")
    func displayName() {
        #expect(Transformer.SwiftEnumLayout.displayName == "Enum Layout Comment")
    }

    @Test("default init")
    func defaultInit() {
        let module = Transformer.SwiftEnumLayout()
        #expect(module.isEnabled == false)
        #expect(module.template == Transformer.SwiftEnumLayout.Templates.strategyOnly)
        #expect(module.caseTemplate == Transformer.SwiftEnumLayout.CaseTemplates.standard)
        #expect(module.useHexadecimal == false)
        #expect(module.memoryOffsetTemplate == Transformer.SwiftEnumLayout.MemoryOffsetTemplates.standard)
    }

    // MARK: - transform (strategy header)

    @Test("transform with strategyOnly template")
    func transformStrategyOnly() {
        let module = Transformer.SwiftEnumLayout(isEnabled: true)
        let input = Transformer.SwiftEnumLayout.Input(
            strategy: "Multi-Payload (Spare Bits)",
            bitsNeededForTag: 2,
            bitsAvailableForPayload: 62,
            numTags: 3
        )
        let result = module.transform(input)
        #expect(result == "Multi-Payload (Spare Bits)")
    }

    @Test("transform with standard template")
    func transformStandard() {
        let module = Transformer.SwiftEnumLayout(isEnabled: true, template: Transformer.SwiftEnumLayout.Templates.standard)
        let input = Transformer.SwiftEnumLayout.Input(
            strategy: "Multi-Payload (Spare Bits)",
            bitsNeededForTag: 2,
            bitsAvailableForPayload: 62,
            numTags: 3
        )
        let result = module.transform(input)
        #expect(result == "Multi-Payload (Spare Bits) (Tags: 3, Tag Bits: 2)")
    }

    @Test("transform with compact template")
    func transformCompact() {
        let module = Transformer.SwiftEnumLayout(isEnabled: true, template: Transformer.SwiftEnumLayout.Templates.compact)
        let input = Transformer.SwiftEnumLayout.Input(
            strategy: "Single-Payload",
            bitsNeededForTag: 1,
            bitsAvailableForPayload: 63,
            numTags: 2
        )
        let result = module.transform(input)
        #expect(result == "Tags: 2, Bits: 1")
    }

    @Test("transform with hex formatting")
    func transformHex() {
        let module = Transformer.SwiftEnumLayout(
            isEnabled: true,
            template: "Tags: ${numTags}",
            useHexadecimal: true
        )
        let input = Transformer.SwiftEnumLayout.Input(
            strategy: "Test",
            bitsNeededForTag: 2,
            bitsAvailableForPayload: 62,
            numTags: 16
        )
        let result = module.transform(input)
        #expect(result == "Tags: 0x10")
    }

    // MARK: - transformCase

    @Test("transformCase with standard template")
    func transformCaseStandard() {
        let module = Transformer.SwiftEnumLayout(isEnabled: true)
        let input = Transformer.SwiftEnumLayout.CaseInput(
            caseIndex: 0,
            caseName: "Payload Case 0",
            tagValue: 0,
            payloadValue: 0
        )
        let result = module.transformCase(input)
        #expect(result.contains("Case 0 (0x00)"))
        #expect(result.contains("Payload Case 0"))
        #expect(result.contains("Tag: 0"))
    }

    @Test("transformCase with compact template")
    func transformCaseCompact() {
        let module = Transformer.SwiftEnumLayout(
            isEnabled: true,
            caseTemplate: Transformer.SwiftEnumLayout.CaseTemplates.compact
        )
        let input = Transformer.SwiftEnumLayout.CaseInput(
            caseIndex: 2,
            caseName: "MyCase",
            tagValue: 1,
            payloadValue: 42
        )
        let result = module.transformCase(input)
        #expect(result == "[2] MyCase (tag: 1)")
    }

    @Test("transformCase hex formatting for caseIndex")
    func transformCaseHex() {
        let module = Transformer.SwiftEnumLayout(
            isEnabled: true,
            caseTemplate: "${caseHex}",
            useHexadecimal: true
        )
        let input = Transformer.SwiftEnumLayout.CaseInput(
            caseIndex: 255,
            caseName: "Test",
            tagValue: 0,
            payloadValue: 0
        )
        let result = module.transformCase(input)
        #expect(result == "0xFF")
    }

    // MARK: - transformMemoryOffset

    @Test("transformMemoryOffset with standard template")
    func transformMemoryOffsetStandard() {
        let module = Transformer.SwiftEnumLayout(isEnabled: true)
        let input = Transformer.SwiftEnumLayout.MemoryOffsetInput(offset: 0, value: 1)
        let result = module.transformMemoryOffset(input)
        #expect(result.contains("Memory Offset 0 (0x00)"))
        #expect(result.contains("0x01"))
        #expect(result.contains("00000001"))
    }

    @Test("transformMemoryOffset with compact template")
    func transformMemoryOffsetCompact() {
        let module = Transformer.SwiftEnumLayout(
            isEnabled: true,
            memoryOffsetTemplate: Transformer.SwiftEnumLayout.MemoryOffsetTemplates.compact
        )
        let input = Transformer.SwiftEnumLayout.MemoryOffsetInput(offset: 3, value: 0xFF)
        let result = module.transformMemoryOffset(input)
        #expect(result == "[3]=0xFF")
    }

    // MARK: - MemoryOffsetInput binary computation

    @Test("MemoryOffsetInput computes binary representations correctly")
    func memoryOffsetInputBinary() {
        let input = Transformer.SwiftEnumLayout.MemoryOffsetInput(offset: 0, value: 42)
        #expect(input.valueBinaryRaw == "101010")
        #expect(input.valueBinary == "0b101010")
        #expect(input.valueBinaryPaddedRaw == "00101010")
        #expect(input.valueBinaryPadded == "0b00101010")
    }

    @Test("MemoryOffsetInput zero value binary")
    func memoryOffsetInputZero() {
        let input = Transformer.SwiftEnumLayout.MemoryOffsetInput(offset: 0, value: 0)
        #expect(input.valueBinaryRaw == "0")
        #expect(input.valueBinaryPaddedRaw == "00000000")
    }

    @Test("MemoryOffsetInput max value binary")
    func memoryOffsetInputMax() {
        let input = Transformer.SwiftEnumLayout.MemoryOffsetInput(offset: 0, value: 255)
        #expect(input.valueBinaryRaw == "11111111")
        #expect(input.valueBinaryPaddedRaw == "11111111")
    }

    // MARK: - contains methods

    @Test("contains checks strategy template token")
    func containsStrategyToken() {
        let module = Transformer.SwiftEnumLayout(template: Transformer.SwiftEnumLayout.Templates.standard)
        #expect(module.contains(.strategy) == true)
        #expect(module.contains(.numTags) == true)
        #expect(module.contains(.bitsNeededForTag) == true)
        #expect(module.contains(.totalCases) == false)
    }

    @Test("containsCase checks case template token")
    func containsCaseToken() {
        let module = Transformer.SwiftEnumLayout(caseTemplate: Transformer.SwiftEnumLayout.CaseTemplates.standard)
        #expect(module.containsCase(.caseIndex) == true)
        #expect(module.containsCase(.caseName) == true)
        #expect(module.containsCase(.tagValue) == true)
        #expect(module.containsCase(.payloadValue) == false)
    }

    @Test("containsMemoryOffset checks memory offset template token")
    func containsMemoryOffsetToken() {
        let module = Transformer.SwiftEnumLayout(memoryOffsetTemplate: Transformer.SwiftEnumLayout.MemoryOffsetTemplates.standard)
        #expect(module.containsMemoryOffset(.offset) == true)
        #expect(module.containsMemoryOffset(.offsetHex) == true)
        #expect(module.containsMemoryOffset(.valueHex) == true)
        #expect(module.containsMemoryOffset(.valueBinaryPaddedRaw) == true)
    }

    // MARK: - Tokens

    @Test("Token allCases has 13 tokens")
    func tokenAllCases() {
        #expect(Transformer.SwiftEnumLayout.Token.allCases.count == 13)
    }

    @Test("CaseToken allCases has 12 tokens")
    func caseTokenAllCases() {
        #expect(Transformer.SwiftEnumLayout.CaseToken.allCases.count == 12)
    }

    @Test("MemoryOffsetToken allCases has 8 tokens")
    func memoryOffsetTokenAllCases() {
        #expect(Transformer.SwiftEnumLayout.MemoryOffsetToken.allCases.count == 8)
    }

    @Test("all token types have non-empty displayNames", arguments: Transformer.SwiftEnumLayout.Token.allCases)
    func tokenDisplayNames(token: Transformer.SwiftEnumLayout.Token) {
        #expect(!token.displayName.isEmpty)
    }

    @Test("all case tokens have non-empty displayNames", arguments: Transformer.SwiftEnumLayout.CaseToken.allCases)
    func caseTokenDisplayNames(token: Transformer.SwiftEnumLayout.CaseToken) {
        #expect(!token.displayName.isEmpty)
    }

    @Test("all memory offset tokens have non-empty displayNames", arguments: Transformer.SwiftEnumLayout.MemoryOffsetToken.allCases)
    func memoryOffsetTokenDisplayNames(token: Transformer.SwiftEnumLayout.MemoryOffsetToken) {
        #expect(!token.displayName.isEmpty)
    }

    // MARK: - Templates

    @Test("Templates.all has 10 entries")
    func strategyTemplatesAll() {
        #expect(Transformer.SwiftEnumLayout.Templates.all.count == 10)
    }

    @Test("CaseTemplates.all has 10 entries")
    func caseTemplatesAll() {
        #expect(Transformer.SwiftEnumLayout.CaseTemplates.all.count == 10)
    }

    @Test("MemoryOffsetTemplates.all has 6 entries")
    func memoryOffsetTemplatesAll() {
        #expect(Transformer.SwiftEnumLayout.MemoryOffsetTemplates.all.count == 6)
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.SwiftEnumLayout(
            isEnabled: true,
            template: "custom ${strategy}",
            caseTemplate: "case ${caseIndex}",
            useHexadecimal: true,
            memoryOffsetTemplate: "[${offset}]"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.SwiftEnumLayout.self, from: data)
        #expect(decoded == original)
    }
}
