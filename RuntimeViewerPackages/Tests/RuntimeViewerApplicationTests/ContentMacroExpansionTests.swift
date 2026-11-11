import Foundation
import RuntimeViewerCore
import Semantic
import Testing
@testable import RuntimeViewerApplication

/// Pins how the content pane carries the attached macros an interface shows folded from the
/// engine's reply to what the SourceEditor pane expands: the attribute's UTF-8 range becomes a
/// UTF-16 range of the text on screen, and a note in place of the text drops them.
@Suite("ContentMacroExpansion")
struct ContentMacroExpansionTests {
    /// The box-drawing prefix is three UTF-8 bytes and one UTF-16 unit, so the attribute below it
    /// sits at different offsets in the two encodings.
    private static let text = """
    // └── a comment ahead of the type
    @Observation.Observable
    final class Model {
        var count: Int
    }
    """

    private static let attribute = "@Observation.Observable"

    private static let expansionText = "    private var _count: Int"

    private static func runtimeObject() -> RuntimeObject {
        RuntimeObject(name: "Model", displayName: "Model", kind: .swift(.type(.class)), imagePath: "/Model", children: [])
    }

    private static func macroExpansion() throws -> RuntimeInterfaceMacroExpansion {
        let utf8Start = try #require(text.utf8.firstRange(of: attribute.utf8)).lowerBound
        let utf8Offset = text.utf8.distance(from: text.utf8.startIndex, to: utf8Start)
        return RuntimeInterfaceMacroExpansion(
            macroName: "Observation.Observable",
            attributeUTF8Range: utf8Offset ..< utf8Offset + attribute.utf8.count,
            expansionString: SemanticString { Standard(expansionText) }.frozen()
        )
    }

    @Test func theAttributeIsLocatedInUTF16OffsetsOfTheRenderedText() throws {
        let fetched = ContentTextViewModel.FetchedInterface(
            interfaceString: SemanticString { Standard(Self.text) }.frozen(),
            runtimeObject: Self.runtimeObject(),
            commentStructure: nil,
            macroExpansions: [try Self.macroExpansion()]
        )

        let rendered = try #require(ContentTextViewModel.renderInterface(for: fetched, theme: ResolvedTheme.fallback))
        let expansion = try #require(rendered.macroExpansions.first)
        #expect(expansion.macroName == "Observation.Observable")
        #expect(expansion.expansionString.string == Self.expansionText)
        let renderedText = rendered.attributedString.string as NSString
        #expect(renderedText.substring(with: expansion.attributeCharacterRange) == Self.attribute)
    }

    @Test func anInterfaceWithoutExpansionsRendersNone() {
        let fetched = ContentTextViewModel.FetchedInterface(
            interfaceString: SemanticString { Standard(Self.text) }.frozen(),
            runtimeObject: Self.runtimeObject(),
            commentStructure: nil
        )
        #expect(ContentTextViewModel.renderInterface(for: fetched, theme: ResolvedTheme.fallback)?.macroExpansions.isEmpty == true)
    }

    /// The note the pane shows in place of an interface the exported-only option empties shifts
    /// the offsets the attributes were taken in, so the expansions go with the text.
    @Test func aNoteInPlaceOfTheTextDropsTheExpansions() throws {
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.printExportedDeclarationsOnly = true
        let interface = RuntimeObjectInterface(object: Self.runtimeObject(), interfaceString: "", macroExpansions: [try Self.macroExpansion()])

        let displayed = ContentTextViewModel.displayedInterface(of: interface, runtimeObject: Self.runtimeObject(), options: options)
        #expect(displayed.macroExpansions.isEmpty)
    }

    @Test func theEngineSendsTheExpansionsOfAFoldedInterfaceThrough() throws {
        let interface = RuntimeObjectInterface(
            object: Self.runtimeObject(),
            interfaceString: SemanticString { Standard(Self.text) }.frozen(),
            macroExpansions: [try Self.macroExpansion()]
        )

        let displayed = ContentTextViewModel.displayedInterface(of: interface, runtimeObject: Self.runtimeObject(), options: .init())
        #expect(displayed.macroExpansions.count == 1)
    }
}
