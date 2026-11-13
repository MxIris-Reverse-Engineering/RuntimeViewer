import Foundation
import RuntimeViewerCore
import Semantic
import Testing
@testable import RuntimeViewerAppCore

/// Pins how the content pane carries the attached macros an interface shows folded from the
/// engine's reply to what the SourceEditor pane expands: the UTF-8 ranges of the attribute and of
/// each part's anchor become UTF-16 ranges of the text on screen, and a note in place of the text
/// drops them.
@Suite("ContentMacroExpansion")
struct ContentMacroExpansionTests {
    /// The box-drawing prefix is three UTF-8 bytes and one UTF-16 unit, so everything below it
    /// sits at different offsets in the two encodings.
    private static let text = """
    // └── a comment ahead of the type
    @Observation.Observable
    final class Model {
        var count: Int
    }
    """

    private static let attribute = "@Observation.Observable"

    private static let declaration = "var count: Int"

    private static let propertyPartText = "{\n    get\n    set\n}\nfinal var _count: Swift.Int"

    private static let membersPartText = "let _$observationRegistrar: Observation.ObservationRegistrar"

    private static func runtimeObject() -> RuntimeObject {
        RuntimeObject(name: "Model", displayName: "Model", kind: .swift(.type(.class)), imagePath: "/Model", children: [])
    }

    /// Where `fragment` is in `text`, in UTF-8 offsets.
    private static func utf8Range(of fragment: String) throws -> Range<Int> {
        let fragmentStart = try #require(text.utf8.firstRange(of: fragment.utf8)).lowerBound
        let utf8Offset = text.utf8.distance(from: text.utf8.startIndex, to: fragmentStart)
        return utf8Offset ..< utf8Offset + fragment.utf8.count
    }

    /// The expansion of `@Observable` on `Model`: a part below `count`'s declaration and a part
    /// above the closing brace, which is the text's last character.
    private static func macroExpansion(
        propertyAnchor: Range<Int>? = nil
    ) throws -> RuntimeInterfaceMacroExpansion {
        let closingBrace = text.utf8.count - 1 ..< text.utf8.count
        return RuntimeInterfaceMacroExpansion(
            macroName: "Observation.Observable",
            attributeUTF8Range: try utf8Range(of: attribute),
            parts: [
                .init(anchorUTF8Range: try propertyAnchor ?? utf8Range(of: declaration), placement: .belowLine,
                      content: SemanticString { Standard(propertyPartText) }.frozen()),
                .init(anchorUTF8Range: closingBrace, placement: .aboveLine,
                      content: SemanticString { Standard(membersPartText) }.frozen()),
            ]
        )
    }

    private static func render(_ expansions: [RuntimeInterfaceMacroExpansion]) throws -> ContentTextViewModel.RenderedInterface {
        let fetched = ContentTextViewModel.FetchedInterface(
            interfaceString: SemanticString { Standard(text) }.frozen(),
            runtimeObject: runtimeObject(),
            commentStructure: nil,
            macroExpansions: expansions
        )
        return try #require(ContentTextViewModel.renderInterface(for: fetched, theme: ResolvedTheme.fallback))
    }

    @Test func theAttributeAndTheAnchorsAreLocatedInUTF16OffsetsOfTheRenderedText() throws {
        let rendered = try Self.render([try Self.macroExpansion()])
        let renderedText = rendered.attributedString.string as NSString

        let expansion = try #require(rendered.macroExpansions.first)
        #expect(expansion.macroName == "Observation.Observable")
        #expect(renderedText.substring(with: expansion.attributeCharacterRange) == Self.attribute)
        try #require(expansion.parts.count == 2)
        #expect(renderedText.substring(with: expansion.parts[0].anchorCharacterRange) == Self.declaration)
        #expect(renderedText.substring(with: expansion.parts[1].anchorCharacterRange) == "}")
        #expect(expansion.parts.map(\.placement) == [.belowLine, .aboveLine])
        #expect(expansion.parts.map(\.content.string) == [Self.propertyPartText, Self.membersPartText])
    }

    /// An anchor inside a character — here the middle of the three bytes of `└` — names no place
    /// in the text on screen: the part goes, and with every part gone the expansion goes too.
    @Test func aPartWhoseAnchorSplitsACharacterIsLeftOut() throws {
        let insideBoxDrawing = 4 ..< 5
        let rendered = try Self.render([try Self.macroExpansion(propertyAnchor: insideBoxDrawing)])
        let expansion = try #require(rendered.macroExpansions.first)
        #expect(expansion.parts.map(\.placement) == [.aboveLine])

        let fetchedWithoutPlaceableParts = RuntimeInterfaceMacroExpansion(
            macroName: "Observation.Observable",
            attributeUTF8Range: try Self.utf8Range(of: Self.attribute),
            parts: [.init(anchorUTF8Range: insideBoxDrawing, placement: .belowLine, content: SemanticString { Standard(Self.propertyPartText) }.frozen())]
        )
        #expect(try Self.render([fetchedWithoutPlaceableParts]).macroExpansions.isEmpty)
    }

    /// `@Observable`'s part for a tracked property is the attribute it puts there, and expanding
    /// that attribute gives the accessors and storage below the declaration. The attribute is found
    /// in the part's own text — here behind a three-byte character, so a UTF-8 offset read as UTF-16
    /// would miss it — and the parts it expands to hang in the rendered text like any other.
    @Test func aNestedExpansionIsLocatedInItsPartAndHangsInTheRenderedText() throws {
        let attributePartText = "/* └ */ @Observation.ObservationTracked"
        let nestedAttribute = "@Observation.ObservationTracked"
        let nestedAttributeStart = attributePartText.utf8.count - nestedAttribute.utf8.count
        let nestedExpansion = RuntimeInterfaceMacroExpansion(
            macroName: "Observation.ObservationTracked",
            attributeUTF8Range: nestedAttributeStart ..< attributePartText.utf8.count,
            parts: [.init(anchorUTF8Range: try Self.utf8Range(of: Self.declaration), placement: .belowLine,
                          content: SemanticString { Standard(Self.propertyPartText) }.frozen())]
        )
        let expansion = RuntimeInterfaceMacroExpansion(
            macroName: "Observation.Observable",
            attributeUTF8Range: try Self.utf8Range(of: Self.attribute),
            parts: [.init(anchorUTF8Range: try Self.utf8Range(of: Self.declaration), placement: .aboveLine,
                          content: SemanticString { Standard(attributePartText) }.frozen(), nestedExpansions: [nestedExpansion])]
        )

        let rendered = try Self.render([expansion])
        let renderedText = rendered.attributedString.string as NSString
        let attributePart = try #require(rendered.macroExpansions.first?.parts.first)
        let renderedNestedExpansion = try #require(attributePart.nestedExpansions.first)
        #expect(attributePart.nestedExpansions.count == 1)
        #expect(renderedNestedExpansion.macroName == "Observation.ObservationTracked")
        #expect((attributePartText as NSString).substring(with: renderedNestedExpansion.attributeCharacterRange) == nestedAttribute)
        let nestedPart = try #require(renderedNestedExpansion.parts.first)
        #expect(renderedText.substring(with: nestedPart.anchorCharacterRange) == Self.declaration)
        #expect(nestedPart.placement == .belowLine)
        #expect(nestedPart.content.string == Self.propertyPartText)
    }

    @Test func anInterfaceWithoutExpansionsRendersNone() throws {
        #expect(try Self.render([]).macroExpansions.isEmpty)
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
