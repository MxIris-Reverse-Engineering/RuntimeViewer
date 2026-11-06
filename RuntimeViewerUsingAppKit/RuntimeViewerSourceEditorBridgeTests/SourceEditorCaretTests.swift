// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// The content pane shows an interface that cannot be edited, so it draws no caret — a blinking
/// one reads as an invitation to type — while text can still be selected and copied.
///
/// The bridge disables editing and turns on `hideCursorWhenEditingDisabled`; with both,
/// `SourceEditorSelectionDisplay.update()` stops the blink and leaves every cursor layer at an
/// opacity of 0, and draws selections as before. Each test focuses the editor in a window that
/// acts as the key window, because the display draws nothing as active anywhere else, and a caret
/// that is transparent only because the editor is inactive would pass for a hidden one.
@Suite("SourceEditorCaret", .serialized)
@MainActor
struct SourceEditorCaretTests {
    private static let source = """
    struct Point {
        var x: Double
    }
    """

    private static let cursorLayerClassName = "CursorLayer"

    private static let selectionLayerClassName = "SelectionLayer"

    private static let insertionPoint = SourceEditorPosition(line: 1, col: 8)

    @Test
    func anInsertionPointDrawsNoCaret() throws {
        let harness = try Self.focusedHarness()
        harness.select(Self.insertionPoint ..< Self.insertionPoint)
        harness.layout()

        let cursorLayers = harness.layers(ofClassNamed: Self.cursorLayerClassName)
        try #require(!cursorLayers.isEmpty, "the editor made no cursor layer for the insertion point")
        #expect(
            cursorLayers.allSatisfy { $0.opacity == 0 },
            "cursor opacities: \(cursorLayers.map(\.opacity))"
        )
    }

    /// The control for the test above: with the switch off, the same insertion point draws a
    /// visible caret, so an opacity of 0 there is the switch's doing and not an inactive display.
    @Test
    func theCaretShowsWithoutTheSwitch() throws {
        let harness = try Self.focusedHarness()
        harness.editorView.hideCursorWhenEditingDisabled = false
        harness.select(Self.insertionPoint ..< Self.insertionPoint)
        harness.layout()

        let cursorLayers = harness.layers(ofClassNamed: Self.cursorLayerClassName)
        try #require(!cursorLayers.isEmpty, "the editor made no cursor layer for the insertion point")
        #expect(
            cursorLayers.contains { $0.opacity == 1 },
            "cursor opacities: \(cursorLayers.map(\.opacity))"
        )
    }

    @Test
    func aSelectionIsStillDrawn() throws {
        let harness = try Self.focusedHarness()
        let selectedRange = SourceEditorPosition(line: 1, col: 4) ..< SourceEditorPosition(line: 1, col: 9)
        harness.select(selectedRange)
        harness.layout()

        #expect(harness.editorView.selection?.primarySelection.range == selectedRange)
        let drawnSelectionLayers = harness.layers(ofClassNamed: Self.selectionLayerClassName).filter { selectionLayer in
            guard let shapeLayer = selectionLayer as? CAShapeLayer, let path = shapeLayer.path else { return false }
            return !shapeLayer.isHidden && shapeLayer.opacity > 0 && !path.boundingBoxOfPath.isEmpty
        }
        #expect(!drawnSelectionLayers.isEmpty, "the selection was not drawn")
    }

    private static func focusedHarness() throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness(actsAsKeyWindow: true)
        harness.setSource(source)
        harness.focusEditor()
        harness.layout()
        return harness
    }
}

#endif
