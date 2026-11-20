#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus

/// An editor pane's jump bar: AppKitPlus's `NSPopUpPathControl` with a context menu of its own on a
/// component, for a secondary click or a Control-click.
///
/// The control has no delegate method for one. Left to itself, a secondary click or a Control-click
/// on a component with a file URL shows the file's enclosing folders, and on any other component
/// opens its ordinary menu. So this subclass finds the component under the pointer
/// (`NSPopUpPathCell.pathComponentCell(at:withFrame:in:)`, whose cell's `representedObject` is the
/// component's item) and asks `contextMenuProvider` for the item's menu. Where it gets none — the
/// engine's component, or a click beside every component — the control does what it always does. A
/// Command-click still shows the enclosing folders.
public final class EditorJumpBarPathControl: NSPopUpPathControl {
    /// The context menu for the item of the component clicked, or `nil` to leave the click to the
    /// control.
    public var contextMenuProvider: ((any NSPopUpPathItem) -> NSMenu?)?

    public override func rightMouseDown(with event: NSEvent) {
        if !popUpContextMenu(for: event) {
            super.rightMouseDown(with: event)
        }
    }

    public override func mouseDown(with event: NSEvent) {
        if !(event.modifierFlags.contains(.control) && popUpContextMenu(for: event)) {
            super.mouseDown(with: event)
        }
    }

    /// Pops up the context menu of the component under `event`; whether there was one to show.
    private func popUpContextMenu(for event: NSEvent) -> Bool {
        let point = convert(event.locationInWindow, from: nil)
        guard let pathCell = cell as? NSPopUpPathCell,
              let componentCell = pathCell.pathComponentCell(at: point, withFrame: bounds, in: self),
              let item = componentCell.representedObject as? any NSPopUpPathItem,
              let menu = contextMenuProvider?(item)
        else { return false }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        return true
    }
}

#endif
