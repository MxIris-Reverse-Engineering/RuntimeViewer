#if os(macOS)

import AppKit

/// The two keys a list page gives a meaning of its own (`StatefulOutlineView.keyDownHandler`),
/// recognized by key code, which does not change with the keyboard layout, and only when pressed
/// without a modifier: ⌘⌫ or ⌥↩ belong to whoever else binds them.
extension NSEvent {
    /// Return, or the numeric keypad's Enter.
    public var isReturnKeyPress: Bool {
        type == .keyDown && Self.returnKeyCodes.contains(keyCode) && hasNoModifierKeys
    }

    /// Delete, or Forward Delete.
    public var isDeleteKeyPress: Bool {
        type == .keyDown && Self.deleteKeyCodes.contains(keyCode) && hasNoModifierKeys
    }

    /// Return (36) and the keypad's Enter (76).
    private static let returnKeyCodes: Set<UInt16> = [36, 76]

    /// Delete (51) and Forward Delete (117).
    private static let deleteKeyCodes: Set<UInt16> = [51, 117]

    /// No Shift, Control, Option or Command. Function and Numeric Pad are left out of the check:
    /// AppKit sets them on Forward Delete and the keypad's Enter themselves.
    private var hasNoModifierKeys: Bool {
        modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty
    }
}

#endif
