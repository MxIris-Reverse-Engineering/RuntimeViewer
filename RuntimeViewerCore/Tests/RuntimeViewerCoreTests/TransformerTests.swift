import Foundation
import Testing
import Semantic
@testable import RuntimeViewerCore

/// The Swift-side transformer template engine moved library-side
/// (MachOSwiftSection's `SemanticTransformer` module), where its behavior is
/// exhaustively unit tested (`TransformerModuleTests`,
/// `EnumLayoutCommentTemplateTests`). This package still owns the ObjC-side
/// modules (`CType`, `ObjCIvarOffset`) and the aggregate persistence
/// `Configuration`, so these tests cover those plus the re-export seam.
@Suite("Transformer")
struct TransformerTests {
    // MARK: - Re-export seam

    @Test("re-exported namespace is visible with the historical spelling")
    func reExportedNamespaceIsVisible() {
        #expect(!Transformer.Configuration.default.hasEnabledModules)
        #expect(Transformer.SwiftEnumLayout.displayName == "Enum Layout Comment")
        #expect(!Transformer.SwiftEnumLayout.CaseTemplates.all.isEmpty)
    }

    @Test("enabled modules render through the library engine")
    func enabledModulesRenderThroughLibraryEngine() {
        var fieldOffsetModule = Transformer.SwiftFieldOffset(isEnabled: true)
        fieldOffsetModule.template = Transformer.SwiftFieldOffset.Templates.range
        #expect(fieldOffsetModule.transform(.init(startOffset: 0, endOffset: 8)) == "0x0 ..< 0x8")

        let compactEnumModule = Transformer.SwiftEnumLayout.compact
        let caseInput = Transformer.SwiftEnumLayout.CaseInput(
            caseIndex: 1,
            caseName: "payload case #1",
            declaredName: "value",
            isPayloadCase: true,
            tagValue: 1,
            payloadValue: 0
        )
        #expect(compactEnumModule.transformCase(caseInput) == "[0x01] `value` — payload case, tag 1")
    }

    // MARK: - ObjC-side modules (still owned here)

    private func semanticKeywords(_ keywords: [String]) -> SemanticString {
        var components: [AtomicComponent] = []
        for (keywordIndex, keyword) in keywords.enumerated() {
            if keywordIndex > 0 {
                components.append(AtomicComponent(string: " ", type: .standard))
            }
            components.append(AtomicComponent(string: keyword, type: .keyword))
        }
        return SemanticString(components: components)
    }

    @Test("CType replaces the longest pattern first")
    func cTypeReplacesLongestPatternFirst() {
        var module = Transformer.CType(isEnabled: true)
        module.replacements = Transformer.CType.Presets.stdint
        // "unsigned long long" must map to uint64_t, not "unsigned" + int64_t.
        #expect(module.transform(semanticKeywords(["unsigned", "long", "long"])).string == "uint64_t")
        #expect(module.transform(semanticKeywords(["long"])).string == "int64_t")
    }

    @Test("CType leaves non-keyword components untouched")
    func cTypeLeavesNonKeywordComponentsUntouched() {
        var module = Transformer.CType(isEnabled: true)
        module.replacements = [.double: "CGFloat"]
        let input = SemanticString(components: [
            AtomicComponent(string: "double", type: .keyword),
            AtomicComponent(string: " ", type: .standard),
            AtomicComponent(string: "value", type: .variable),
        ])
        #expect(module.transform(input).string == "CGFloat value")
    }

    @Test("ObjCIvarOffset renders its template")
    func objcIvarOffsetRendersTemplate() {
        let module = Transformer.ObjCIvarOffset(isEnabled: true)
        #expect(module.transform(.init(offset: 8)) == "offset: 0x8")
    }

    // MARK: - Aggregate persistence

    @Test("configuration persistence round-trips and tolerates missing keys")
    func configurationPersistenceRoundTrips() throws {
        var configuration = Transformer.Configuration()
        configuration.swift.swiftFieldOffset.isEnabled = true
        configuration.swift.swiftEnumLayout = .explained
        configuration.objc.cType = .init(isEnabled: true, replacements: Transformer.CType.Presets.foundation)

        let encoded = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(Transformer.Configuration.self, from: encoded)
        #expect(decoded == configuration)

        // Settings stored by older versions may lack any key.
        let emptyDecoded = try JSONDecoder().decode(Transformer.Configuration.self, from: Data("{}".utf8))
        #expect(emptyDecoded == .default)
    }

    @Test("hasEnabledModules covers both sides")
    func hasEnabledModulesCoversBothSides() {
        var configuration = Transformer.Configuration.default
        #expect(!configuration.hasEnabledModules)
        configuration.objc.ivarOffset.isEnabled = true
        #expect(configuration.hasEnabledModules)
        configuration = .default
        configuration.swift.swiftTypeLayout.isEnabled = true
        #expect(configuration.hasEnabledModules)
    }
}
