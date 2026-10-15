#if os(macOS)

import AppKit
import UIFoundation

/// A plain view that AppKit's scroll pockets take for a bar: it answers `_scrollPocketElementStyle` with
/// `NSView.barScrollPocketElementStyle`, the value Xcode's bars answer. Use it for a bar that floats over a list and is
/// registered as a container of the list's scroll pocket through `NavigatorScrollViewLayout` — the tab switcher's bar,
/// the Find page's query area and summary row.
///
/// Xcode's own is DVTUserInterfaceKit's `NSViewWithScrollPocketElementStyleBar` (27.2, 0xD5F68), which its Find
/// navigator's nib uses for the summary rows; the navigator chooser, `IDETwoLevelChooserView`, answers the same value
/// (IDEKit 27.2, 0x2A3268).
public final class ScrollPocketBarView: NSView {
    @available(macOS 26.0, *)
    public override var _scrollPocketElementStyle: Int {
        NSView.barScrollPocketElementStyle
    }
}

#endif
