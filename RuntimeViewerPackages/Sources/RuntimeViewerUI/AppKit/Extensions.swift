#if os(macOS)

import AppKit

extension NSPopUpButton {
    public var popUpButtonCell: NSPopUpButtonCell? {
        cell as? NSPopUpButtonCell
    }
}


#endif
