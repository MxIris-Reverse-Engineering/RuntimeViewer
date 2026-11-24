// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import QuartzCore
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers the bridge's line-end tags, which the content pane uses to say a C-imported type's other
/// name after its declaration and to switch to it on a click (proposal
/// `c-imported-type-name-spelling` in MachOSwiftSection): a capsule a space past the end of the line,
/// drawn in the editor's underlay with a text layer of its own.
@Suite("LineEndTag", .serialized)
@MainActor
struct LineEndTagTests {
    private static let source = """
    struct Holder {}
    struct AnyWeakAttribute {
        var seed: Swift.UInt32
    }
    """

    /// `struct AnyWeakAttribute {`, the second line.
    private static let declarationLine = 1
    private static let declarationLineLength = "struct AnyWeakAttribute {".utf16.count

    /// `AnyWeakAttribute`, on the second line. Nonisolated: it is the default of `tag(at:identifier:)`.
    private nonisolated static let declaredNameRange = NSRange(location: ("struct Holder {}\nstruct " as NSString).length,
                                                   length: "AnyWeakAttribute".utf16.count)

    /// `Holder`, on the first line.
    private static let holderNameRange = NSRange(location: ("struct " as NSString).length, length: "Holder".utf16.count)

    private static func tag(at range: NSRange = declaredNameRange, identifier: String = "0") -> SourceEditorBridgingLineEndTag {
        SourceEditorBridgingLineEndTag(
            characterRange: range,
            label: "C name",
            value: "AGWeakAttribute",
            valueStyle: .type,
            toolTip: "Show C Names",
            identifier: identifier
        )
    }

    private static func harnessShowingTag(identifier: String = "0") throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness()
        harness.setSource(source)
        harness.layout()
        harness.showLineEndTags([tag(identifier: identifier)])
        harness.layout()
        return harness
    }

    @Test("a tag sits a space past the end of the line its range starts on, with its label and value")
    func tagSitsPastTheEndOfTheLineItsRangeStartsOn() throws {
        let harness = try Self.harnessShowingTag()
        let textLayers = Self.shownTextLayers(in: harness)
        let capsules = Self.shownCapsuleLayers(in: harness)
        try #require(textLayers.count == 1 && capsules.count == 1, "\(textLayers.count) text layers, \(capsules.count) capsules")
        let textLayer = textLayers[0]
        let capsule = capsules[0]
        #expect((textLayer.string as? NSAttributedString)?.string == "C name AGWeakAttribute")

        let lastCharacter = try #require(Self.frame(ofColumns: Self.declarationLineLength - 1 ..< Self.declarationLineLength, onLine: Self.declarationLine, in: harness))
        #expect(capsule.frame.minX > lastCharacter.maxX, "capsule \(capsule.frame) against the brace \(lastCharacter)")
        #expect(capsule.frame.minX < lastCharacter.maxX + 3 * lastCharacter.width, "capsule \(capsule.frame) against the brace \(lastCharacter)")
        #expect(abs(capsule.frame.midY - lastCharacter.midY) < 1)
        #expect(capsule.frame.minX < textLayer.frame.minX && textLayer.frame.maxX <= capsule.frame.maxX, "text \(textLayer.frame) in capsule \(capsule.frame)")
    }

    /// The tag is drawn beside the text, so the line the editor lays out is the source's own.
    @Test("a tag adds nothing to the text")
    func tagAddsNothingToTheText() throws {
        let harness = try Self.harnessShowingTag()
        let line = try #require(harness.editorView.layoutManager.lineLayerForVisibleLine(Self.declarationLine))
        #expect(line.attributedString.string == "struct AnyWeakAttribute {")
    }

    @Test("showing tags again replaces the ones shown")
    func showingAgainReplaces() throws {
        let harness = try Self.harnessShowingTag()
        harness.showLineEndTags([Self.tag(at: Self.holderNameRange, identifier: "1"), Self.tag(identifier: "2")])
        harness.layout()
        #expect(Self.shownTextLayers(in: harness).count == 2)
        harness.showLineEndTags([])
        harness.layout()
        #expect(Self.shownTextLayers(in: harness).isEmpty)
        #expect(Self.shownCapsuleLayers(in: harness).isEmpty)
    }

    /// A tag was placed on a line of the text it was shown on, which the next text does not have.
    @Test("a new source removes every tag")
    func setSourceRemovesTags() throws {
        let harness = try Self.harnessShowingTag()
        harness.setSource("struct Other {}")
        harness.layout()
        #expect(Self.shownTextLayers(in: harness).isEmpty)
        #expect(Self.shownCapsuleLayers(in: harness).isEmpty)
    }

    /// The click is the tag's: the editor would otherwise start tracking a selection, and
    /// `mouseDown(with:)` would not return before a mouse-up arrived.
    @Test("clicking a tag tells the delegate which tag it was")
    func clickingNotifiesDelegateWithIdentifier() throws {
        let harness = try Self.harnessShowingTag(identifier: "7")
        let delegate = RecordingNavigationDelegate()
        harness.navigationDelegate = delegate
        let capsule = try #require(Self.shownCapsuleLayers(in: harness).first)

        Self.send(.leftMouseDown, at: CGPoint(x: capsule.frame.midX, y: capsule.frame.midY), in: harness)
        Self.send(.leftMouseUp, at: CGPoint(x: capsule.frame.midX, y: capsule.frame.midY), in: harness)

        #expect(delegate.clickedIdentifiers == ["7"])
    }

    /// The editor adds its I-beam and then what each provider answers, all on itself, so the hands
    /// are read back where it adds them.
    @Test("over a tag the pointer is a pointing hand")
    func tagTakesThePointingHand() throws {
        let harness = try Self.harnessShowingTag()
        let capsule = try #require(Self.shownCapsuleLayers(in: harness).first)
        let added = CursorRectRecorder.cursorRects(addedBy: harness.editorView) {
            harness.editorView.resetCursorRects()
        }
        let handRects = added.filter { $0.cursor === NSCursor.pointingHand }.map(\.rect)
        let center = harness.editorView.convert(CGPoint(x: capsule.frame.midX, y: capsule.frame.midY), from: harness.editorView.contentView)
        #expect(handRects.count == 1, "\(handRects)")
        #expect(handRects.contains { $0.contains(center) }, "no pointing hand over the tag at \(center): \(handRects)")
    }

    @Test("hovering a tag darkens it and shows its tool tip, and leaving it undoes both")
    func hoveringDarkensTagAndShowsToolTip() throws {
        let harness = try Self.harnessShowingTag()
        let capsule = try #require(Self.shownCapsuleLayers(in: harness).first)
        let restingAlpha = try #require(capsule.fillColor?.alpha)
        let contentView = harness.editorView.contentView

        Self.send(.mouseMoved, at: CGPoint(x: capsule.frame.midX, y: capsule.frame.midY), in: harness)
        #expect(try #require(capsule.fillColor?.alpha) > restingAlpha)
        #expect(contentView.toolTip == "Show C Names")

        let firstCharacter = try #require(Self.frame(ofColumns: 0 ..< 1, onLine: 0, in: harness))
        Self.send(.mouseMoved, at: CGPoint(x: firstCharacter.midX, y: firstCharacter.midY), in: harness)
        #expect(capsule.fillColor?.alpha == restingAlpha)
        #expect(contentView.toolTip == nil)
    }

    // MARK: - Helpers

    private static func shownTextLayers(in harness: SourceEditorTestHarness) -> [CATextLayer] {
        (harness.editorView.contentView.underlayLayer.sublayers ?? [])
            .compactMap { $0 as? CATextLayer }
            .filter { !$0.isHidden }
    }

    /// With no comment decorations, the only shapes drawn in the underlay are the tags' capsules.
    private static func shownCapsuleLayers(in harness: SourceEditorTestHarness) -> [CAShapeLayer] {
        (harness.editorView.contentView.underlayLayer.sublayers ?? [])
            .compactMap { $0 as? CAShapeLayer }
            .filter { !$0.isHidden && $0.path != nil }
    }

    /// Where the columns are drawn, in the content view's coordinates.
    private static func frame(ofColumns columns: Range<Int>, onLine line: Int, in harness: SourceEditorTestHarness) -> CGRect? {
        let range = SourceEditorPosition(line: line, col: columns.lowerBound) ..< SourceEditorPosition(line: line, col: columns.upperBound)
        let rects = harness.editorView.contentView.selectionRects(for: range, coalesceInteriorRects: true, includeLineSpacing: false)
            .map(\.rect)
            .filter { $0.width > 0 && $0.height > 0 }
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// A mouse event at `point` in the content view, sent the way AppKit sends one.
    private static func send(_ type: NSEvent.EventType, at point: CGPoint, in harness: SourceEditorTestHarness) {
        let contentView = harness.editorView.contentView
        guard let window = contentView.window else { return }
        guard let event = NSEvent.mouseEvent(
            with: type,
            location: contentView.convert(point, to: nil),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: type == .mouseMoved ? 0 : 1,
            pressure: type == .leftMouseDown ? 1 : 0
        ) else { return }
        switch type {
        case .leftMouseDown: harness.editorView.mouseDown(with: event)
        case .leftMouseUp: harness.editorView.mouseUp(with: event)
        case .mouseMoved: harness.editorView.mouseMoved(with: event)
        default: break
        }
    }

    /// Stands in for the content pane: records the tags clicked.
    private final class RecordingNavigationDelegate: NSObject, SourceEditorBridgingNavigationDelegate {
        private(set) var clickedIdentifiers: [String] = []

        func sourceEditorBridge(_ bridge: SourceEditorBridging, didCommandClickTokenIn characterRange: NSRange) {}

        func sourceEditorBridge(_ bridge: SourceEditorBridging, contextualMenuItemsForTokenIn characterRange: NSRange) -> [NSMenuItem] {
            []
        }

        func sourceEditorBridge(
            _ bridge: SourceEditorBridging,
            contextualMenuItemsForTokenIn characterRange: NSRange,
            inInlineExpansionPartAt partIndex: Int,
            identifier: String
        ) -> [NSMenuItem] {
            []
        }

        func sourceEditorBridge(_ bridge: SourceEditorBridging, didClickLineEndTagWithIdentifier identifier: String) {
            clickedIdentifiers.append(identifier)
        }
    }
}

#endif
