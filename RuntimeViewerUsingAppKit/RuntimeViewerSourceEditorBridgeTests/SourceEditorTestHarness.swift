// Compiled only where the reconstructed SourceEditor frameworks are on the framework search path,
// as the bridge under test is.
#if arch(arm64) && canImport(SourceEditor)

import AppKit
import QuartzCore
import SourceEditor
@testable import RuntimeViewerSourceEditorBridge

/// Builds the bridge the way the content pane does and puts its editor view somewhere a layout
/// pass will actually run. The test bundle links the bridge framework and the reconstructed
/// frameworks directly, so nothing here launches the app.
///
/// Driving the bridge rather than a bare `SourceEditorView` is the point: the ordering under
/// test lives in `SourceEditorBridge.setSource`, and a test that built its own view would pass
/// no matter what that method does.
@MainActor
final class SourceEditorTestHarness {
    private let bridge: SourceEditorBridging
    private let window: NSWindow

    /// The editor view the bridge built, for the tests that register their own layout providers
    /// on its layout manager or measure its content view.
    let editorView: SourceEditorView

    /// The view's folding controller, which is where the state under test lives.
    let foldingController: FoldingController

    /// The scroll view the editor builds for itself and keeps as a direct subview.
    let scrollView: NSScrollView

    /// - Parameter actsAsKeyWindow: makes the window answer `isKeyWindow` with `true`. The test
    ///   process is never the active application, so a real window never becomes key, and the
    ///   editor draws its selection and cursor as active only while it is the first responder of
    ///   the key window.
    init(actsAsKeyWindow: Bool = false) throws {
        let bridge = SourceEditorBridge()
        self.bridge = bridge

        guard let editorView = bridge.editorView as? SourceEditorView else {
            throw HarnessError.editorViewUnexpectedType(type(of: bridge.editorView))
        }
        self.editorView = editorView
        self.foldingController = editorView.foldingController
        self.scrollView = editorView.scrollView

        // Off-screen is enough — measured. What the crash needs is a layer-backed view whose
        // layoutSublayers(of:) runs inside a CoreAnimation transaction, not a visible window.
        let window = HarnessWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.actsAsKeyWindow = actsAsKeyWindow
        self.window = window
        window.contentView = editorView
        window.orderFront(nil)
    }

    /// How many lines the text last passed to `setSource` has.
    private(set) var lineCount = 0

    /// Narrows or widens the window the editor fills: how far a line runs before the editor
    /// wraps it.
    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: window.contentLayoutRect.height))
    }

    /// Hands the bridge the tag appearance, as the content pane does with each theme.
    func applyCommentTagAppearance(_ appearance: SourceEditorBridgingCommentTagAppearance) {
        bridge.applyCommentTagAppearance(appearance)
    }

    /// Turns the gutter's line numbers on, the way the content pane does when Settings shows them.
    func showLineNumbers() {
        bridge.applyDisplayOptions(
            showsLineNumbers: true,
            showsFoldingRibbon: false,
            showsStickyHeaders: false,
            showsMinimap: false,
            showsScopeGuides: false,
            showsInvisibles: false,
            showsMarkSeparators: false,
            showsInsertionPoint: false
        )
    }

    /// Turns the caret on or off, the way the content pane does when Settings › Editor ›
    /// Insertion Point changes. Every other option is passed as `init` leaves it.
    func showInsertionPoint(_ showsInsertionPoint: Bool) {
        bridge.applyDisplayOptions(
            showsLineNumbers: true,
            showsFoldingRibbon: false,
            showsStickyHeaders: false,
            showsMinimap: false,
            showsScopeGuides: false,
            showsInvisibles: false,
            showsMarkSeparators: false,
            showsInsertionPoint: showsInsertionPoint
        )
    }

    /// - Parameters:
    ///   - semanticRanges: UTF-16 ranges into `source`, as the content pane passes the runs the
    ///     interface generator recorded.
    ///   - semanticNodeTypeNames: parallel to `semanticRanges`: the node type each run is retyped to.
    ///   - restoresScrollPosition: as the content pane passes it, `false` when a reveal follows.
    func setSource(
        _ source: String,
        semanticRanges: [NSRange] = [],
        semanticNodeTypeNames: [String] = [],
        commentDecorations: SourceEditorBridgingCommentDecorations? = nil,
        restoresScrollPosition: Bool = true
    ) {
        lineCount = source.components(separatedBy: "\n").count
        bridge.setSource(
            source,
            languageIdentifier: "swift",
            semanticRanges: semanticRanges.map { NSValue(range: $0) },
            semanticNodeTypeNames: semanticNodeTypeNames,
            commentDecorations: commentDecorations,
            restoresScrollPosition: restoresScrollPosition
        )
    }

    /// Reveals a UTF-16 range of the source, as the content pane does with a Find navigator hit.
    func revealCharacterRange(_ characterRange: NSRange) {
        bridge.revealCharacterRange(characterRange)
    }

    /// Shows `source` below the line holding `anchorRange`, as the content pane does with a
    /// macro's expansion.
    func showInlineExpansion(_ source: String, title: String, identifier: String,
                             belowLineContaining anchorRange: NSRange) {
        bridge.showInlineExpansion(
            source,
            languageIdentifier: "swift",
            semanticRanges: [],
            semanticNodeTypeNames: [],
            title: title,
            identifier: identifier,
            belowLineContaining: anchorRange
        )
    }

    func hideInlineExpansion(identifier: String) {
        bridge.hideInlineExpansion(identifier: identifier)
    }

    func isInlineExpansionShown(identifier: String) -> Bool {
        bridge.isInlineExpansionShown(identifier: identifier)
    }

    /// Opens the find bar on `query`, as the content pane does with a Find navigator text hit.
    func showFindInterface(query: String, pattern: SourceEditorBridgingFindPattern, isCaseSensitive: Bool) {
        bridge.showFindInterface(query: query, pattern: pattern, isCaseSensitive: isCaseSensitive)
    }

    /// The tokens the language service reports on `line`, each with the columns it covers. This
    /// is the enumeration the editor colours a line from.
    func syntaxTokens(onLine line: Int) -> [(type: SourceEditorTokenType, columns: Range<Int>)] {
        var tokens: [(type: SourceEditorTokenType, columns: Range<Int>)] = []
        editorView.dataSource.languageService.enumerateSyntaxTokensOnLine(line) { tokenType, columns in
            tokens.append((tokenType, columns))
        }
        return tokens
    }

    /// Gives the editor view keyboard focus, as a click into the content pane does.
    func focusEditor() {
        window.makeFirstResponder(editorView)
    }

    /// Takes keyboard focus away from the editor, leaving it with the window — where it is, for the
    /// editor, while the reader is in another pane.
    func focusWindow() {
        window.makeFirstResponder(nil)
    }

    /// Where keyboard focus is.
    var firstResponder: NSResponder? {
        window.firstResponder
    }

    /// Selects `range`, or puts the insertion point there when it is empty, as a click or a drag
    /// in the editor does.
    func select(_ range: Range<SourceEditorPosition>) {
        editorView.selectTextRange(range, scrollIfNeeded: false)
    }

    /// Every layer under the editor view whose class is called `className`, such as the
    /// framework's internal `CursorLayer`, which a test cannot name as a type.
    func layers(ofClassNamed className: String) -> [CALayer] {
        var matchingLayers: [CALayer] = []
        var pendingLayers: [CALayer] = editorView.layer.map { [$0] } ?? []
        while let layer = pendingLayers.popLast() {
            if String(describing: type(of: layer)) == className {
                matchingLayers.append(layer)
            }
            pendingLayers.append(contentsOf: layer.sublayers ?? [])
        }
        return matchingLayers
    }

    /// Forces the layout the crash happens inside.
    ///
    /// `layoutSubtreeIfNeeded()` alone is not enough: the trap is reached from
    /// `NSViewBackingLayer.layoutSublayers`, which runs when the CoreAnimation transaction
    /// commits. The short run-loop spin lets a transaction the framework scheduled itself land
    /// as well.
    func layout() {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        CATransaction.begin()
        CATransaction.flush()
        CATransaction.commit()
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
    }

    /// Lays out until `condition` holds, for work the framework finishes later — at the end of an
    /// animation, or after a delay.
    ///
    /// Suspends between passes rather than only spinning the run loop: a test runs as a job on
    /// the main queue, which is serial, so what the framework schedules there itself —
    /// `TimeoutContinuation` is `DispatchQueue.main.asyncAfter` — runs only once the test lets go.
    ///
    /// - Returns: whether `condition` held before `timeout` ran out.
    func layout(until condition: () -> Bool, timeout: Duration = .seconds(3)) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            layout()
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        } while clock.now < deadline
        return false
    }

    /// A window that can claim to be the key window, for `init(actsAsKeyWindow: true)`.
    private final class HarnessWindow: NSWindow {
        var actsAsKeyWindow = false

        override var isKeyWindow: Bool { actsAsKeyWindow || super.isKeyWindow }
    }

    enum HarnessError: Error, CustomStringConvertible {
        case editorViewUnexpectedType(Any.Type)

        var description: String {
            switch self {
            case .editorViewUnexpectedType(let type):
                "the bridge handed back a \(type) rather than a SourceEditorView"
            }
        }
    }
}

#endif
