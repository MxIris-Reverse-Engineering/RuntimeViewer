// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers the bridge's line annotations, which the content pane uses to say a C-imported type's other
/// name at the end of its declaration and offer to switch to it (proposal
/// `c-imported-type-name-spelling` in MachOSwiftSection): Xcode's issue annotations, inserted into the
/// editor's own line annotation manager.
@Suite("LineAnnotation", .serialized)
@MainActor
struct LineAnnotationTests {
    private static let source = """
    struct Holder {}
    struct AnyWeakAttribute {
        var seed: Swift.UInt32
    }
    """

    /// `AnyWeakAttribute`, on the second line.
    private static let declaredNameRange = NSRange(location: ("struct Holder {}\nstruct " as NSString).length,
                                                   length: "AnyWeakAttribute".utf16.count)

    private static func annotation(identifier: String = "0") -> SourceEditorBridgingLineAnnotation {
        SourceEditorBridgingLineAnnotation(
            characterRange: declaredNameRange,
            message: "Imported from C as AGWeakAttribute",
            actionTitle: "Show C Names",
            identifier: identifier
        )
    }

    private static func harnessShowingAnnotation() throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness()
        harness.setSource(source)
        harness.layout()
        harness.showLineAnnotations([annotation()])
        harness.layout()
        return harness
    }

    @Test("an annotation sits on the line its range starts on, with its message")
    func lineAnnotationSitsOnFirstLineOfItsRange() throws {
        let harness = try Self.harnessShowingAnnotation()
        let annotations = harness.editorView.lineAnnotations
        #expect(annotations.count == 1)
        let annotation = try #require(annotations.first)
        #expect(annotation.message == "Imported from C as AGWeakAttribute")
        #expect(annotation.lineIdentifier == harness.editorView.dataSource.identifierForLine(1))
        #expect(annotation.category == SourceEditorBridge.noteLineAnnotationCategory)
    }

    @Test("showing annotations again replaces the ones shown")
    func showingAgainReplaces() throws {
        let harness = try Self.harnessShowingAnnotation()
        harness.showLineAnnotations([Self.annotation(identifier: "1")])
        harness.layout()
        #expect(harness.editorView.lineAnnotations.count == 1)
        harness.showLineAnnotations([])
        harness.layout()
        #expect(harness.editorView.lineAnnotations.isEmpty)
    }

    /// An annotation is filed under a line identifier of the data source it was shown on, which the
    /// next source's data source does not have.
    @Test("a new source removes every annotation")
    func setSourceRemovesLineAnnotations() throws {
        let harness = try Self.harnessShowingAnnotation()
        harness.setSource("struct Other {}")
        harness.layout()
        #expect(harness.editorView.lineAnnotations.isEmpty)
    }

    @Test("performing the action tells the delegate which annotation it was")
    func performingActionNotifiesDelegateWithIdentifier() throws {
        let harness = try Self.harnessShowingAnnotation()
        let delegate = RecordingNavigationDelegate()
        harness.navigationDelegate = delegate
        harness.showLineAnnotations([Self.annotation(identifier: "7")])
        harness.layout()
        let annotation = try #require(harness.editorView.lineAnnotations.first)
        let action = try #require(annotation.actions.first)
        #expect(action.message == "Show C Names")
        action.perform(nil)
        action.perform(nil)
        #expect(delegate.performedIdentifiers == ["7", "7"])
    }

    @Test("the annotation's contextual menu offers the action too")
    func contextualMenuOffersTheSameAction() throws {
        let harness = try Self.harnessShowingAnnotation()
        let annotation = try #require(harness.editorView.lineAnnotations.first)
        #expect(annotation.revealAction != nil)
    }

    /// Stands in for the content pane: records the line annotation actions performed.
    private final class RecordingNavigationDelegate: NSObject, SourceEditorBridgingNavigationDelegate {
        private(set) var performedIdentifiers: [String] = []

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

        func sourceEditorBridge(_ bridge: SourceEditorBridging, didPerformActionOfLineAnnotationWithIdentifier identifier: String) {
            performedIdentifiers.append(identifier)
        }
    }
}

#endif
