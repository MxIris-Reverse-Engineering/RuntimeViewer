import Foundation
@_spi(Support) import SwiftPrinting
import Testing
@testable import RuntimeViewerCore

/// The spelling of C-imported type names on the engine (proposal `c-imported-type-name-spelling` in
/// MachOSwiftSection): the Swift Generation Option that picks the Swift or the C name, and the names
/// the engine sends a viewer that offers the other one.
///
/// AttributeGraph is where the report came from: its `AGWeakAttribute` is imported to Swift as
/// `AnyWeakAttribute`, and its declaration printed the Swift name while its extensions printed the
/// C one.
@Suite("C-imported type name spelling on the engine", .serialized)
struct CImportedTypeNameSpellingEngineTests {
    private struct FixtureMissing: Error {}

    private static let attributeGraphPath = "/System/Library/PrivateFrameworks/AttributeGraph.framework/Versions/A/AttributeGraph"

    private static func flattened(_ runtimeObjects: [RuntimeObject]) -> [RuntimeObject] {
        runtimeObjects.flatMap { [$0] + flattened($0.children) }
    }

    /// One engine for the suite, with AttributeGraph's `AGWeakAttribute` as the engine lists it.
    private static let shared = Task<(engine: RuntimeEngine, weakAttribute: RuntimeObject), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "CImportedTypeNameSpellingEngineTests")
        try await engine.connect()
        try await engine.loadImage(at: attributeGraphPath)
        let objects = flattened(try await engine.objects(in: attributeGraphPath))
        let listedNames: Set<String> = ["AGWeakAttribute", "__C.AGWeakAttribute", "AnyWeakAttribute"]
        guard let weakAttribute = objects.first(where: { $0.kind.isSwift && listedNames.contains($0.displayName) }) else {
            throw FixtureMissing()
        }
        return (engine, weakAttribute)
    }

    private static func options(spelling: SwiftGenerationOptions.CImportedTypeNameSpelling, marksCImportedTypeNames: Bool = false, marksCommentStructure: Bool = false) -> RuntimeObjectInterface.GenerationOptions {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.cImportedTypeNameSpelling = spelling
        options.marksCImportedTypeNames = marksCImportedTypeNames
        options.marksCommentStructure = marksCommentStructure
        return options
    }

    private static func interface(_ options: RuntimeObjectInterface.GenerationOptions) async throws -> RuntimeObjectInterface {
        let (engine, weakAttribute) = try await shared.value
        return try #require(try await engine.interface(for: weakAttribute, options: options))
    }

    private static func text(of name: RuntimeInterfaceCImportedTypeName, in interface: RuntimeObjectInterface) -> String {
        let bytes = Array(interface.interfaceString.string.utf8)
        return String(decoding: bytes[name.nameUTF8Range], as: UTF8.self)
    }

    // MARK: - Options

    @Test("Options from before the spelling decode with Swift names and no marking")
    func spellingDefaultsToSwiftNameInOlderPayload() throws {
        let savedOptions = Data(#"{"swiftInterfaceOptions":{"synthesizeOpaqueType":true}}"#.utf8)
        let decodedOptions = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: savedOptions)
        #expect(decodedOptions.swiftInterfaceOptions.cImportedTypeNameSpelling == .swiftName)
        #expect(!decodedOptions.marksCImportedTypeNames)
        #expect(RuntimeObjectInterface.GenerationOptions().swiftInterfaceOptions.cImportedTypeNameSpelling == .swiftName)
    }

    @Test("The spelling's raw values are what the settings store")
    func spellingRawValuesAreStable() {
        #expect(SwiftGenerationOptions.CImportedTypeNameSpelling.swiftName.rawValue == "swiftName")
        #expect(SwiftGenerationOptions.CImportedTypeNameSpelling.cName.rawValue == "cName")
        #expect(SwiftGenerationOptions.CImportedTypeNameSpelling.swiftName.toggled == .cName)
        #expect(SwiftGenerationOptions.CImportedTypeNameSpelling.cName.toggled == .swiftName)
    }

    /// The Find corpus is printed with the switches the options map to; it keeps Swift names.
    @Test("The switches the corpus reads leave the spelling alone")
    func corpusPrintsSwiftNamesWhateverTheSpelling() {
        var swiftOptions = SwiftGenerationOptions()
        swiftOptions.cImportedTypeNameSpelling = .cName
        var configuration = SwiftDeclarationPrintConfiguration()
        configuration.applySwitches(of: swiftOptions)
        #expect(configuration.cImportedTypeNameSpelling == .swiftName)
    }

    // MARK: - Interfaces

    @Test("Spelling Swift names prints the declaration, its members and its extensions under one name")
    func swiftSpellingIsUniform() async throws {
        let interface = try await Self.interface(Self.options(spelling: .swiftName))
        let text = interface.interfaceString.string
        #expect(text.contains("struct AnyWeakAttribute"), "\(text)")
        #expect(text.contains("AnyWeakAttribute.__Unnamed_struct__details"), "\(text)")
        #expect(text.contains("extension AnyWeakAttribute: "), "\(text)")
        #expect(!text.contains("AGWeakAttribute"), "\(text)")
        #expect(interface.cImportedTypeNames == nil)
    }

    @Test("Spelling C names prints the names the binary mangles")
    func cSpellingIsUniform() async throws {
        let text = try await Self.interface(Self.options(spelling: .cName)).interfaceString.string
        #expect(text.contains("struct AGWeakAttribute"), "\(text)")
        #expect(text.contains("__C.AGWeakAttribute.__Unnamed_struct__details"), "\(text)")
        #expect(text.contains("extension __C.AGWeakAttribute: "), "\(text)")
        #expect(!text.contains("AnyWeakAttribute"), "\(text)")
    }

    @Test("A marked interface carries both names of the declared type, at the name it prints")
    func interfaceCarriesCImportedTypeNamesWhenMarked() async throws {
        let unmarked = try await Self.interface(Self.options(spelling: .swiftName))
        let marked = try await Self.interface(Self.options(spelling: .swiftName, marksCImportedTypeNames: true))
        #expect(marked.interfaceString.string == unmarked.interfaceString.string)
        let names = try #require(marked.cImportedTypeNames)
        let weakAttribute = try #require(names.first { $0.cName == "AGWeakAttribute" })
        #expect(weakAttribute.swiftName == "AnyWeakAttribute")
        #expect(Self.text(of: weakAttribute, in: marked) == "AnyWeakAttribute")

        let markedCSpelling = try await Self.interface(Self.options(spelling: .cName, marksCImportedTypeNames: true))
        let weakAttributeInCSpelling = try #require(markedCSpelling.cImportedTypeNames?.first { $0.cName == "AGWeakAttribute" })
        #expect(weakAttributeInCSpelling.swiftName == "AnyWeakAttribute")
        #expect(Self.text(of: weakAttributeInCSpelling, in: markedCSpelling) == "AGWeakAttribute")
    }

    @Test("The comment structure leaves the C-imported type names out")
    func commentStructureIgnoresCImportedTypeNameRegions() async throws {
        let interface = try await Self.interface(Self.options(spelling: .swiftName, marksCImportedTypeNames: true, marksCommentStructure: true))
        #expect(interface.cImportedTypeNames?.isEmpty == false)
        let comments = try #require(interface.commentStructure).comments
        #expect(!comments.contains { $0.kind.rawValue.hasPrefix("cImportedTypeName") })
    }
}
