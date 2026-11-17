import Testing
import Foundation
@testable import RuntimeViewerCore

/// An Objective-C class Swift implements (MachOSwiftSection's evolution proposal
/// `swift-first-imported-declarations`), over SceneHosting's `SHScenePresentation` on macOS 27.2:
/// an `@objc @implementation` class whose header refines `layerFilter` and `settings` for Swift.
/// Its header carries `NS_REFINED_FOR_SWIFT` back on those two, in the display and in the Find
/// corpus alike, and its Generated Interface is its Swift side.
@Suite("Interfaces of a class Swift implements", .serialized)
struct SwiftImplementedClassInterfaceTests {
    private struct MissingObject: Error {
        let description: String
    }

    private static let sceneHostingPath = "/System/Library/PrivateFrameworks/SceneHosting.framework/Versions/A/SceneHosting"

    /// One engine for the suite, with SceneHosting loaded, and its `SHScenePresentation`.
    private static let shared = Task<(engine: RuntimeEngine, presentation: RuntimeObject), any Error> {
        let engine = RuntimeEngine(source: .local, engineID: "SwiftImplementedClassInterfaceTests")
        try await engine.connect()
        try await engine.loadImage(at: sceneHostingPath)
        let objects = try await engine.objects(in: sceneHostingPath)
        guard let presentation = objects.first(where: { $0.kind == .objc(.type(.class)) && $0.name == "SHScenePresentation" }) else {
            throw MissingObject(description: "SceneHosting lists no SHScenePresentation")
        }
        return (engine, presentation)
    }

    private static func defaultOptions(interfaceLanguage: RuntimeInterfaceLanguage? = nil) throws -> RuntimeObjectInterface.GenerationOptions {
        var options = try JSONDecoder().decode(RuntimeObjectInterface.GenerationOptions.self, from: Data("{}".utf8))
        options.interfaceLanguage = interfaceLanguage
        return options
    }

    @Test("the header marks the members Swift knows by another name NS_REFINED_FOR_SWIFT")
    func headerCarriesTheMacro() async throws {
        let (engine, presentation) = try await Self.shared.value
        let interface = try #require(try await engine.interface(for: presentation, options: Self.defaultOptions()))
        let header = interface.interfaceString.string
        #expect(interface.interfaceLanguage == .objectiveC)
        #expect(header.contains("*layerFilter NS_REFINED_FOR_SWIFT;"), "\(header)")
        #expect(header.contains("*settings NS_REFINED_FOR_SWIFT;"), "\(header)")
        #expect(header.components(separatedBy: "NS_REFINED_FOR_SWIFT").count == 3, "\(header)")
    }

    @Test("the Find corpus prints the header with the same macros")
    func corpusCarriesTheMacro() async throws {
        let (engine, presentation) = try await Self.shared.value
        let printing = try await engine.corpusPrinting(forImageAt: Self.sceneHostingPath)
        let outcomes = try await printing.prints(of: [presentation], transformer: Transformer.Configuration())
        guard case .printed(let corpusPrint)? = outcomes.first else {
            Issue.record("SHScenePresentation printed no corpus entry: \(outcomes)")
            return
        }
        let text = corpusPrint.interface.string
        #expect(text.contains("*layerFilter NS_REFINED_FOR_SWIFT;"), "\(text)")
        #expect(text.contains("*settings NS_REFINED_FOR_SWIFT;"), "\(text)")
    }

    @Test("the Generated Interface is the class's Swift side")
    func generatedInterfaceIsTheSwiftSide() async throws {
        let (engine, presentation) = try await Self.shared.value
        let interface = try #require(try await engine.interface(for: presentation, options: Self.defaultOptions(interfaceLanguage: .swift)))
        let text = interface.interfaceString.string
        #expect(interface.interfaceLanguage == .swift)
        #expect(text.contains("func isHosting(sceneLayer:"), "\(text)")
        #expect(!text.contains("isHostingSceneLayer"), "\(text)")
        #expect(text.contains("var __layerFilter:"), "\(text)")
        #expect(text.contains("// NS_REFINED_FOR_SWIFT: var __settings:"), "\(text)")
    }
}
