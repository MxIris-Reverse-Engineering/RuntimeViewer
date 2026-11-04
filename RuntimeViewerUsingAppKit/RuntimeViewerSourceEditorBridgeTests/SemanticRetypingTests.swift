// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
import SourceModelSupport
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Pins the path that colours a type *reference* from what the interface generator recorded.
///
/// The parser alone types `Float` in `var linearRed: Swift.Float` as a plain identifier: nothing in
/// the text says it names a type. `SemanticNodeTypeAdjuster` retypes it from the semantic run the
/// app hands `setSource`, but only if the framework consults the adjuster, and that depends on the
/// didSet of `SourceModelLanguageService.nodeTypeAdjuster` passing it on to the syntax token
/// provider. SourceEditor 26.6.1 left that observer out (in Xcode 26.6 the setter, at 0x23908,
/// calls it at 0x23734), so the adjuster was never asked: every type reference in every interface
/// lost its colour, while keywords and declarations, which the grammar types by itself, kept theirs.
/// SourceEditor 26.6.2 restored the observer.
///
/// The tokens come from `enumerateSyntaxTokensOnLine`, which is what the editor colours a line
/// from. The test therefore covers the bridge installing the adjuster, the framework consulting it,
/// and the retyped node reaching the token the theme is looked up by.
@Suite("SemanticRetyping", .serialized)
@MainActor
struct SemanticRetypingTests {
    private static let source = """
    struct Color {
        var linearRed: Swift.Float
    }
    """

    /// What the app assigns to every type-name semantic; see
    /// `SourceEditorThemeConversion.syntaxColorKey(for:)`.
    private static let typeReferenceNodeTypeName = "xcode.syntax.identifier.class"

    @Test
    func aTypeReferenceTakesItsTypeFromTheSemanticRun() throws {
        let harness = try SourceEditorTestHarness()
        let text = Self.source as NSString
        let typeNameRange = text.range(of: "Float")
        let keywordRange = text.range(of: "var")
        let lineRange = text.lineRange(for: typeNameRange)

        harness.setSource(
            Self.source,
            semanticRanges: [typeNameRange],
            semanticNodeTypeNames: [Self.typeReferenceNodeTypeName]
        )
        harness.layout()

        let tokens = harness.syntaxTokens(onLine: 1)

        // The grammar types the keyword by itself. Checking it first makes a failure below mean
        // that the type name was not retyped, not that the line was never tokenized.
        let keywordColumn = keywordRange.location - lineRange.location
        let keywordToken = try #require(tokens.first { $0.columns.contains(keywordColumn) })
        #expect(keywordToken.type == .keyword(nil))

        let typeNameColumn = typeNameRange.location - lineRange.location
        let typeNameToken = try #require(tokens.first { $0.columns.contains(typeNameColumn) })
        #expect(typeNameToken.type == .identifier(SourceModelIdentifierKind.class(.project)))
    }
}

#endif
