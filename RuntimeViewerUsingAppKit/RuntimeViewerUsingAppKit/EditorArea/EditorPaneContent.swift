import AppKit

/// A content view controller an editor pane shows, which says what takes the keyboard focus when
/// the pane does — Xcode's `takeFocus`: after Move Focus to Next Editor Pane, after a new pane
/// opens, after the focused pane closes.
///
/// Deliberately not `preferredFirstResponder`: AppKitPlus's navigation controller hands the focus
/// to that at the end of every `set`, so a pane switching from its placeholder to an interface
/// would take the focus from the sidebar the user is clicking through.
protocol EditorPaneContent: AnyObject {
    var focusableView: NSView? { get }
}

extension ContentTextViewController: EditorPaneContent {}

extension ContentSourceEditorViewController: EditorPaneContent {}
