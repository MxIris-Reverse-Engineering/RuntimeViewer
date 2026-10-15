#if os(macOS)

import AppKit
import AppKitPlus
import UIFoundation

/// The filter bar at the bottom of a navigator page: AppKitPlus's `NSFilterControlBar`, taken for a bar by AppKit's
/// scroll pockets as Xcode's filter bar is (`-[DVTFilterExpressionControlBar _scrollPocketElementStyle]`,
/// DVTUserInterfaceKit 27.2, 0xA3A38). A plain `NSFilterControlBar` answers as any view does.
///
/// Hand it to the page's `NavigatorScrollViewLayout` as a bottom overlay, which registers it with the list's scroll view
/// as the container of the bottom scroll pocket.
public final class NavigatorFilterControlBar: NSFilterControlBar {
    @available(macOS 26.0, *)
    public override var _scrollPocketElementStyle: Int {
        NSView.barScrollPocketElementStyle
    }
}

#endif
