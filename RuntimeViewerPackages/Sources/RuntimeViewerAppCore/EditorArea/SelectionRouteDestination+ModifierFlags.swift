#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit

extension SelectionRoute.Destination {
    /// Where a click in a list of objects — the sidebar's object list, the Find results, the
    /// Inspector's lists — opens one: a plain click in the focused pane's tab, ⌥ in the next pane,
    /// ⇧⌥ in a new tab of the focused pane. That is Xcode with its optional navigation set to "Uses
    /// Separate Editor"; Xcode 27.2's defaults have ⌥ and ⇧⌥ the other way round (proposal
    /// `option-click-next-editor-pane`). Only Option and Shift count; ⇧ alone is a plain click.
    public init(listClickModifierFlags modifierFlags: NSEvent.ModifierFlags) {
        switch modifierFlags.intersection([.option, .shift]) {
        case [.option]: self = .nextEditorPane
        case [.option, .shift]: self = .newTab
        default: self = .focusedTab
        }
    }

    /// Where a ⌘-click on a type link in the content opens the type: as a list click, except that ⇧
    /// alone opens a new tab as well, as ⇧⌘-click always has here.
    public init(linkClickModifierFlags modifierFlags: NSEvent.ModifierFlags) {
        switch modifierFlags.intersection([.option, .shift]) {
        case [.option]: self = .nextEditorPane
        case [.option, .shift], [.shift]: self = .newTab
        default: self = .focusedTab
        }
    }
}
#endif
