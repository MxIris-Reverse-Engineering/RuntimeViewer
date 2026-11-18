#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RuntimeViewerAppCore

/// How a Find result the user chose is opened, read off the event that chose it.
public enum FindResultActivation {
    /// Where the result opens: with ⌥ held in the next editor pane, with ⇧⌥ in a new tab, otherwise
    /// in the focused tab (proposal `option-click-next-editor-pane`).
    public static func destination(for triggeringEvent: NSEvent?) -> SelectionRoute.Destination {
        SelectionRoute.Destination(listClickModifierFlags: triggeringEvent?.modifierFlags ?? [])
    }

    /// Whether `triggeringEvent` is a character typed into the list, which selects a row by its
    /// text one keystroke at a time. A click, an arrow key and a change AppKit reports with no
    /// event are each a choice of their own.
    public static func isTypeSelect(_ triggeringEvent: NSEvent?) -> Bool {
        guard let triggeringEvent, triggeringEvent.type == .keyDown else { return false }
        return !arrowKeyCodes.contains(triggeringEvent.keyCode)
    }

    /// Left, right, down and up.
    private static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]
}
#endif
