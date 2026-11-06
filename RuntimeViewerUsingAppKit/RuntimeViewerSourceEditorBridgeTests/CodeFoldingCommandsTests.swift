// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import ObjectiveC
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// The Editor ▸ Code Folding menu names its actions through `SourceEditorBridgingCodeFoldingCommands`
/// and sends them up the responder chain to the editor view, which implements and enables them
/// itself. Nothing checks at compile time that the view answers those selectors, so the first test
/// does: a release of the framework that renamed one would leave its menu item greyed out for good.
@Suite("CodeFoldingCommands", .serialized)
@MainActor
struct CodeFoldingCommandsTests {
    private static let source = """
    class Widget {
        var first: Int
        var second: Int
        var third: Int
    }
    """

    /// The empty insertion point inside the class body, where a click leaves it.
    private static let insertionPoint = SourceEditorPosition(line: 2, col: 4)

    private static var commandSelectors: [Selector] {
        var methodCount: UInt32 = 0
        guard let descriptions = protocol_copyMethodDescriptionList(
            SourceEditorBridgingCodeFoldingCommands.self, true, true, &methodCount
        ) else { return [] }
        defer { free(descriptions) }
        return (0 ..< Int(methodCount)).compactMap { descriptions[$0].name }
    }

    @Test
    func theEditorViewAnswersEveryCommandTheMenuSends() {
        let selectors = Self.commandSelectors
        #expect(selectors.count == 5)
        for selector in selectors {
            #expect(
                class_getInstanceMethod(SourceEditorView.self, selector) != nil,
                "SourceEditorView does not implement \(selector)"
            )
        }
    }

    @Test
    func theEditorEnablesTheCommands() throws {
        let harness = try SourceEditorTestHarness(actsAsKeyWindow: true)
        harness.setSource(Self.source)
        harness.focusEditor()
        harness.layout()

        for selector in Self.commandSelectors {
            let menuItem = NSMenuItem(title: "", action: selector, keyEquivalent: "")
            #expect(harness.editorView.validateUserInterfaceItem(menuItem), "\(selector) is disabled")
        }
    }

    /// Fold and Unfold All, sent the way a menu sends them: to the first responder, which passes
    /// what it does not handle up the chain.
    @Test
    func foldAndUnfoldAllReachTheEditorThroughTheResponderChain() async throws {
        let harness = try SourceEditorTestHarness(actsAsKeyWindow: true)
        harness.setSource(Self.source)
        harness.focusEditor()
        harness.select(Self.insertionPoint ..< Self.insertionPoint)
        harness.layout()
        let firstResponder = try #require(harness.firstResponder)

        #expect(firstResponder.tryToPerform(#selector(SourceEditorBridgingCodeFoldingCommands.fold(_:)), with: nil))
        let didFold = await harness.layout(until: { !harness.foldingController.foldedRanges(containing: 2).isEmpty })
        #expect(didFold, "Fold left the class body around the insertion point open")

        #expect(firstResponder.tryToPerform(#selector(SourceEditorBridgingCodeFoldingCommands.unfoldAll(_:)), with: nil))
        let didUnfold = await harness.layout(until: { harness.foldingController.foldedRanges(containing: 2).isEmpty })
        #expect(didUnfold, "Unfold All left a fold in place")
    }
}

#endif
