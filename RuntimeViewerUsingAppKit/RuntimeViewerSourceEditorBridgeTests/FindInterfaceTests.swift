// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge
import Testing

/// Covers `SourceEditorBridge.showFindInterface`, which the content pane calls with the search a
/// Find navigator text hit came from: the find bar opens on that query, matched the same way,
/// with every match marked — and keyboard focus stays where it was, so the reader can go on
/// stepping through the navigator's results.
///
/// The query also lands on the system's find pasteboard, as with any find bar; each test puts
/// back what was there.
@Suite("FindInterface", .serialized)
@MainActor
struct FindInterfaceTests {
    private static let source = """
    class Widget {
        var widgetCount: Int
        func widget()
        func resetWidgets()
    }
    """

    /// Runs `body` and then puts the find pasteboard back as it was.
    private static func preservingFindPasteboard(_ body: () throws -> Void) rethrows {
        let findPasteboard = NSPasteboard(name: .find)
        let savedString = findPasteboard.string(forType: .string)
        defer {
            findPasteboard.clearContents()
            if let savedString {
                findPasteboard.setString(savedString, forType: .string)
            }
        }
        try body()
    }

    private static func focusedElsewhereHarness() throws -> SourceEditorTestHarness {
        let harness = try SourceEditorTestHarness(actsAsKeyWindow: true)
        harness.setSource(source)
        harness.layout()
        harness.focusWindow()
        return harness
    }

    @Test
    func theFindBarOpensWithEveryMatchMarked() throws {
        try Self.preservingFindPasteboard {
            let harness = try Self.focusedElsewhereHarness()

            harness.showFindInterface(query: "widget", pattern: .contains, isCaseSensitive: false)
            harness.layout()

            #expect(harness.editorView.textFindPanelDisplayed)
            #expect(harness.editorView.findResultDisplayMode == .All)
            #expect(harness.editorView.findResult?.matchingRanges.count == 4)
        }
    }

    @Test
    func theFocusStaysWhereItWas() throws {
        try Self.preservingFindPasteboard {
            let harness = try Self.focusedElsewhereHarness()
            let focusBefore = try #require(harness.firstResponder)

            harness.showFindInterface(query: "widget", pattern: .contains, isCaseSensitive: false)
            harness.layout()

            #expect(harness.firstResponder === focusBefore, "the find bar took the focus: \(String(describing: harness.firstResponder))")
        }
    }

    /// The pattern and the case setting come across too: a whole-word, case-sensitive `widget`
    /// is the method alone.
    @Test
    func theMatchStyleComesAcross() throws {
        try Self.preservingFindPasteboard {
            let harness = try Self.focusedElsewhereHarness()

            harness.showFindInterface(query: "widget", pattern: .matchesWord, isCaseSensitive: true)
            harness.layout()

            #expect(harness.editorView.findQuery.pattern == .matchesWord)
            #expect(harness.editorView.findQuery.isCaseSensitive)
            #expect(harness.editorView.findResult?.matchingRanges == [
                SourceEditorPosition(line: 2, col: 9) ..< SourceEditorPosition(line: 2, col: 15),
            ])
        }
    }

    /// The reader opens a second hit with the bar still open from the first: the bar takes the
    /// new query, and its matches are drawn although the editor does not have the focus — the
    /// query's own observer hides them in that case, and opening the bar again shows them.
    @Test
    func anOpenFindBarTakesTheNextQuery() throws {
        try Self.preservingFindPasteboard {
            let harness = try Self.focusedElsewhereHarness()
            harness.showFindInterface(query: "widget", pattern: .contains, isCaseSensitive: false)
            harness.layout()

            harness.showFindInterface(query: "resetWidgets", pattern: .contains, isCaseSensitive: true)
            harness.layout()

            #expect(harness.editorView.findResult?.matchingRanges.count == 1)
            #expect(harness.editorView.findResultDisplayMode == .All)
        }
    }
}

#endif
