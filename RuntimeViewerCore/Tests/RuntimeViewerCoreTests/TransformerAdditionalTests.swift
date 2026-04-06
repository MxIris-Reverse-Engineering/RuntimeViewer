import Testing
import Foundation
import RuntimeViewerCore

// MARK: - SwiftVTableOffset Tests

@Suite("Transformer.SwiftVTableOffset")
struct TransformerSwiftVTableOffsetTests {
    // MARK: - Basic Properties

    @Test("Display name")
    func displayName() {
        #expect(Transformer.SwiftVTableOffset.displayName == "Swift VTable Offset Comment")
    }

    @Test("Default initialization")
    func defaultInit() {
        let module = Transformer.SwiftVTableOffset()
        #expect(module.isEnabled == false)
        #expect(module.template == Transformer.SwiftVTableOffset.Templates.standard)
        #expect(module.labeledTemplate == Transformer.SwiftVTableOffset.Templates.standardLabeled)
        #expect(module.useHexadecimal == false)
    }

    @Test("Custom initialization")
    func customInit() {
        let module = Transformer.SwiftVTableOffset(
            isEnabled: true,
            template: "custom ${slotOffset}",
            labeledTemplate: "custom labeled ${slotOffset} ${label}",
            useHexadecimal: true
        )
        #expect(module.isEnabled == true)
        #expect(module.template == "custom ${slotOffset}")
        #expect(module.labeledTemplate == "custom labeled ${slotOffset} ${label}")
        #expect(module.useHexadecimal == true)
    }

    // MARK: - Transform

    @Test("Transform with standard template (no label)")
    func transformStandard() {
        let module = Transformer.SwiftVTableOffset()
        let result = module.transform(.init(slotOffset: 42, label: nil))
        #expect(result == "VTable Offset: 42")
    }

    @Test("Transform with standard labeled template")
    func transformStandardLabeled() {
        let module = Transformer.SwiftVTableOffset()
        let result = module.transform(.init(slotOffset: 42, label: "getter"))
        #expect(result == "VTable Offset (getter): 42")
    }

    @Test("Transform with compact template (no label)")
    func transformCompact() {
        let module = Transformer.SwiftVTableOffset(template: Transformer.SwiftVTableOffset.Templates.compact)
        let result = module.transform(.init(slotOffset: 10, label: nil))
        #expect(result == "VTable[10]")
    }

    @Test("Transform with compact labeled template")
    func transformCompactLabeled() {
        let module = Transformer.SwiftVTableOffset(
            labeledTemplate: Transformer.SwiftVTableOffset.Templates.compactLabeled
        )
        let result = module.transform(.init(slotOffset: 10, label: "setter"))
        #expect(result == "VTable[10] (setter)")
    }

    @Test("Transform with offset-only template")
    func transformOffsetOnly() {
        let module = Transformer.SwiftVTableOffset(template: Transformer.SwiftVTableOffset.Templates.offsetOnly)
        let result = module.transform(.init(slotOffset: 255, label: nil))
        #expect(result == "255")
    }

    @Test("Transform with hexadecimal formatting")
    func transformHexadecimal() {
        let module = Transformer.SwiftVTableOffset(useHexadecimal: true)
        let result = module.transform(.init(slotOffset: 255, label: nil))
        #expect(result == "VTable Offset: 0xFF")
    }

    @Test("Transform with hexadecimal and label")
    func transformHexadecimalLabeled() {
        let module = Transformer.SwiftVTableOffset(useHexadecimal: true)
        let result = module.transform(.init(slotOffset: 16, label: "getter"))
        #expect(result == "VTable Offset (getter): 0x10")
    }

    @Test("Transform with zero offset")
    func transformZeroOffset() {
        let module = Transformer.SwiftVTableOffset()
        let result = module.transform(.init(slotOffset: 0, label: nil))
        #expect(result == "VTable Offset: 0")
    }

    @Test("Transform uses template when label is nil, labeledTemplate when label is provided")
    func transformTemplateSelection() {
        let module = Transformer.SwiftVTableOffset(
            template: "UNLABELED: ${slotOffset}",
            labeledTemplate: "LABELED: ${slotOffset} ${label}"
        )
        let unlabeledResult = module.transform(.init(slotOffset: 5, label: nil))
        #expect(unlabeledResult == "UNLABELED: 5")

        let labeledResult = module.transform(.init(slotOffset: 5, label: "test"))
        #expect(labeledResult == "LABELED: 5 test")
    }

    @Test("Transform with empty label still uses labeledTemplate")
    func transformEmptyLabel() {
        let module = Transformer.SwiftVTableOffset()
        let result = module.transform(.init(slotOffset: 42, label: ""))
        // label is non-nil (empty string), so labeledTemplate is used
        #expect(result == "VTable Offset (): 42")
    }

    // MARK: - Contains

    @Test("Contains token checks both templates")
    func containsToken() {
        let module = Transformer.SwiftVTableOffset()
        #expect(module.contains(.slotOffset) == true)
        #expect(module.contains(.label) == true)  // label is in labeledTemplate
    }

    @Test("Contains returns false for absent token")
    func containsAbsentToken() {
        let module = Transformer.SwiftVTableOffset(
            template: "no tokens here",
            labeledTemplate: "still no tokens"
        )
        #expect(module.contains(.slotOffset) == false)
        #expect(module.contains(.label) == false)
    }

    @Test("Contains returns true when token is only in one template")
    func containsInOneTemplate() {
        let module = Transformer.SwiftVTableOffset(
            template: "${slotOffset}",
            labeledTemplate: "no offset token"
        )
        #expect(module.contains(.slotOffset) == true)
    }

    // MARK: - Token

    @Test("Token placeholders", arguments: [
        (Transformer.SwiftVTableOffset.Token.slotOffset, "${slotOffset}"),
        (.label, "${label}"),
    ] as [(Transformer.SwiftVTableOffset.Token, String)])
    func tokenPlaceholder(token: Transformer.SwiftVTableOffset.Token, expected: String) {
        #expect(token.placeholder == expected)
    }

    @Test("Token display names", arguments: [
        (Transformer.SwiftVTableOffset.Token.slotOffset, "Slot Offset"),
        (.label, "Label"),
    ] as [(Transformer.SwiftVTableOffset.Token, String)])
    func tokenDisplayName(token: Transformer.SwiftVTableOffset.Token, expected: String) {
        #expect(token.displayName == expected)
    }

    @Test("Token allCases count")
    func tokenAllCases() {
        #expect(Transformer.SwiftVTableOffset.Token.allCases.count == 2)
    }

    // MARK: - Templates

    @Test("Templates.all count")
    func templatesAllCount() {
        #expect(Transformer.SwiftVTableOffset.Templates.all.count == 3)
    }

    @Test("Templates.allLabeled count")
    func templatesAllLabeledCount() {
        #expect(Transformer.SwiftVTableOffset.Templates.allLabeled.count == 3)
    }

    @Test("All templates contain slotOffset token")
    func templatesContainOffset() {
        for (_, template) in Transformer.SwiftVTableOffset.Templates.all {
            #expect(template.contains("${slotOffset}"))
        }
    }

    @Test("All labeled templates contain slotOffset token")
    func labeledTemplatesContainOffset() {
        for (_, template) in Transformer.SwiftVTableOffset.Templates.allLabeled {
            #expect(template.contains("${slotOffset}"))
        }
    }

    @Test("Standard templates match expected values")
    func standardTemplateValues() {
        #expect(Transformer.SwiftVTableOffset.Templates.standard == "VTable Offset: ${slotOffset}")
        #expect(Transformer.SwiftVTableOffset.Templates.standardLabeled == "VTable Offset (${label}): ${slotOffset}")
        #expect(Transformer.SwiftVTableOffset.Templates.compact == "VTable[${slotOffset}]")
        #expect(Transformer.SwiftVTableOffset.Templates.compactLabeled == "VTable[${slotOffset}] (${label})")
        #expect(Transformer.SwiftVTableOffset.Templates.offsetOnly == "${slotOffset}")
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.SwiftVTableOffset(
            isEnabled: true,
            template: "custom ${slotOffset}",
            labeledTemplate: "labeled ${slotOffset} ${label}",
            useHexadecimal: true
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.SwiftVTableOffset.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable decoding with missing fields uses defaults")
    func codableDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Transformer.SwiftVTableOffset.self, from: json)
        #expect(decoded.isEnabled == false)
        #expect(decoded.template == Transformer.SwiftVTableOffset.Templates.standard)
        #expect(decoded.labeledTemplate == Transformer.SwiftVTableOffset.Templates.standardLabeled)
        #expect(decoded.useHexadecimal == false)
    }

    // MARK: - Equatable / Hashable

    @Test("Equatable")
    func equatable() {
        let moduleA = Transformer.SwiftVTableOffset(isEnabled: true, useHexadecimal: true)
        let moduleB = Transformer.SwiftVTableOffset(isEnabled: true, useHexadecimal: true)
        let moduleC = Transformer.SwiftVTableOffset(isEnabled: false, useHexadecimal: true)
        #expect(moduleA == moduleB)
        #expect(moduleA != moduleC)
    }
}

// MARK: - SwiftMemberAddress Tests

@Suite("Transformer.SwiftMemberAddress")
struct TransformerSwiftMemberAddressTests {
    // MARK: - Basic Properties

    @Test("Display name")
    func displayName() {
        #expect(Transformer.SwiftMemberAddress.displayName == "Swift Member Address Comment")
    }

    @Test("Default initialization")
    func defaultInit() {
        let module = Transformer.SwiftMemberAddress()
        #expect(module.isEnabled == false)
        #expect(module.template == Transformer.SwiftMemberAddress.Templates.standard)
        #expect(module.useHexadecimal == true)
    }

    @Test("Custom initialization")
    func customInit() {
        let module = Transformer.SwiftMemberAddress(
            isEnabled: true,
            template: "custom ${offset}",
            useHexadecimal: false
        )
        #expect(module.isEnabled == true)
        #expect(module.template == "custom ${offset}")
        #expect(module.useHexadecimal == false)
    }

    // MARK: - Transform

    @Test("Transform with standard template (hex)")
    func transformStandardHex() {
        let module = Transformer.SwiftMemberAddress()
        let result = module.transform(.init(offset: 0x1234))
        #expect(result == "Address: 0x1234")
    }

    @Test("Transform with standard template (decimal)")
    func transformStandardDecimal() {
        let module = Transformer.SwiftMemberAddress(useHexadecimal: false)
        let result = module.transform(.init(offset: 4660))
        #expect(result == "Address: 4660")
    }

    @Test("Transform with compact template")
    func transformCompact() {
        let module = Transformer.SwiftMemberAddress(template: Transformer.SwiftMemberAddress.Templates.compact)
        let result = module.transform(.init(offset: 0xFF))
        #expect(result == "0xFF")
    }

    @Test("Transform with labeled template")
    func transformLabeled() {
        let module = Transformer.SwiftMemberAddress(template: Transformer.SwiftMemberAddress.Templates.labeled)
        let result = module.transform(.init(offset: 0xAB))
        #expect(result == "addr: 0xAB")
    }

    @Test("Transform with zero offset")
    func transformZeroOffset() {
        let module = Transformer.SwiftMemberAddress()
        let result = module.transform(.init(offset: 0))
        #expect(result == "Address: 0x0")
    }

    @Test("Transform with large offset (hex)")
    func transformLargeOffset() {
        let module = Transformer.SwiftMemberAddress()
        let result = module.transform(.init(offset: 0xDEADBEEF))
        #expect(result == "Address: 0xDEADBEEF")
    }

    @Test("Transform with custom template")
    func transformCustomTemplate() {
        let module = Transformer.SwiftMemberAddress(template: "offset=${offset}")
        let result = module.transform(.init(offset: 256))
        #expect(result == "offset=0x100")
    }

    // MARK: - Contains

    @Test("Contains offset token in standard template")
    func containsOffsetToken() {
        let module = Transformer.SwiftMemberAddress()
        #expect(module.contains(.offset) == true)
    }

    @Test("Contains returns false for absent token")
    func containsAbsentToken() {
        let module = Transformer.SwiftMemberAddress(template: "no tokens here")
        #expect(module.contains(.offset) == false)
    }

    // MARK: - Token

    @Test("Token placeholder")
    func tokenPlaceholder() {
        #expect(Transformer.SwiftMemberAddress.Token.offset.placeholder == "${offset}")
    }

    @Test("Token display name")
    func tokenDisplayName() {
        #expect(Transformer.SwiftMemberAddress.Token.offset.displayName == "Offset")
    }

    @Test("Token allCases count")
    func tokenAllCases() {
        #expect(Transformer.SwiftMemberAddress.Token.allCases.count == 1)
    }

    // MARK: - Templates

    @Test("Templates.all count")
    func templatesAllCount() {
        #expect(Transformer.SwiftMemberAddress.Templates.all.count == 3)
    }

    @Test("All templates contain offset token")
    func templatesContainOffset() {
        for (_, template) in Transformer.SwiftMemberAddress.Templates.all {
            #expect(template.contains("${offset}"))
        }
    }

    @Test("Standard template values")
    func standardTemplateValues() {
        #expect(Transformer.SwiftMemberAddress.Templates.standard == "Address: ${offset}")
        #expect(Transformer.SwiftMemberAddress.Templates.compact == "${offset}")
        #expect(Transformer.SwiftMemberAddress.Templates.labeled == "addr: ${offset}")
    }

    // MARK: - Codable

    @Test("Codable round-trip")
    func codable() throws {
        let original = Transformer.SwiftMemberAddress(
            isEnabled: true,
            template: "custom ${offset}",
            useHexadecimal: false
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Transformer.SwiftMemberAddress.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable decoding with missing fields uses defaults")
    func codableDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Transformer.SwiftMemberAddress.self, from: json)
        #expect(decoded.isEnabled == false)
        #expect(decoded.template == Transformer.SwiftMemberAddress.Templates.standard)
        #expect(decoded.useHexadecimal == true)
    }

    // MARK: - Equatable / Hashable

    @Test("Equatable")
    func equatable() {
        let moduleA = Transformer.SwiftMemberAddress(isEnabled: true, useHexadecimal: false)
        let moduleB = Transformer.SwiftMemberAddress(isEnabled: true, useHexadecimal: false)
        let moduleC = Transformer.SwiftMemberAddress(isEnabled: false, useHexadecimal: false)
        #expect(moduleA == moduleB)
        #expect(moduleA != moduleC)
    }
}
