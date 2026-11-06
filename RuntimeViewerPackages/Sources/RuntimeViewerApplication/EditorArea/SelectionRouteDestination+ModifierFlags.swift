#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension SelectionRoute.Destination {
    /// Where a click in a list of objects — the sidebar's object list, the Find results, the
    /// Inspector's References — opens one, by Xcode 27.2's defaults: a plain click in the focused
    /// pane's tab, ⌥ in a new tab of the focused pane, ⇧⌥ in the next pane (proposal
    /// `draft-editor-panes`). Only Option and Shift count; ⇧ alone is a plain click.
    public init(listClickModifierFlags modifierFlags: NSEvent.ModifierFlags) {
        switch modifierFlags.intersection([.option, .shift]) {
        case [.option, .shift]: self = .nextEditorPane
        case [.option]: self = .newTab
        default: self = .focusedTab
        }
    }

    /// Where a ⌘-click on a type link in the content opens the type: as a list click, except that ⇧
    /// alone opens a new tab as well, as ⇧⌘-click always has here.
    public init(linkClickModifierFlags modifierFlags: NSEvent.ModifierFlags) {
        switch modifierFlags.intersection([.option, .shift]) {
        case [.option, .shift]: self = .nextEditorPane
        case [.option], [.shift]: self = .newTab
        default: self = .focusedTab
        }
    }
}
#endif
