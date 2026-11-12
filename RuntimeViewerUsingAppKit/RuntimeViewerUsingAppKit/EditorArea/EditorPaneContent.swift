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

    /// The scroll view whose content runs under the pane's tab bar — UIKit's
    /// `contentScrollView(for:)`, for the top edge only. The pane registers its tab bar as a
    /// container of this scroll view's top scroll pocket, so the interface scrolled under the bar
    /// shows through it blurred. `nil` when the content has none.
    var contentScrollView: NSScrollView? { get }
}

extension ContentTextViewController: EditorPaneContent {}

extension ContentSourceEditorViewController: EditorPaneContent {}
