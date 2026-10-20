#if os(macOS)

import AppKit
import UIFoundation

/// A one-point horizontal line: an `NSBox` of type `.separator` that never reports an intrinsic width. Use it for a
/// line laid across a pane — the one between a navigator page's list and its filter bar, a line between the sections
/// of a popover — never a plain separator box.
///
/// A plain separator box works out for itself whether it is horizontal or vertical, and can get it wrong for good.
/// While its bounds are no more than 5 points either way, as they are before its first layout, AppKit takes the
/// direction from the width and height the layout engine holds for the box at that moment, and makes it vertical when
/// the height is not less than the width (`NSBoxSeparatorVisualProvider`, AppKit 26.7, 0x18501F0E0). A vertical box
/// has an intrinsic width of 1 at a content hugging priority of 750, and AppKit does not invalidate that intrinsic size
/// once the box turns out to be horizontal: the engine keeps `width == 1` at 750 until something invalidates it or the
/// box leaves the window. Pinned to both edges of a sidebar page, that holds the whole sidebar at its minimum width,
/// and no divider drag moves it. The sidebar's first page met exactly that: the window's first constraint pass runs
/// from AppKitPlus's navigation bar (`-[NSBar _updateTrailingViewWithItemContainer:]`) while the window restores,
/// before the split view has given the sidebar any width, so the box was 0 wide and 1 tall.
///
/// Answering no intrinsic width leaves the engine nothing to keep; the box still draws as AppKit draws a separator.
/// Background: `Documentations/ResolvedIssues/2026-10-20-sidebar-divider-locked-by-a-separator.md`.
public final class HorizontalSeparatorView: Box {
    public override func setup() {
        super.setup()

        boxType = .separator
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 1)
    }

    /// A line between a navigator page's list and the bars above or below it, which the page draws in its stacked
    /// layout, before macOS 26 only. `nil` from macOS 26, where the list runs under the bars and fades out there
    /// instead, as in Xcode (see `NavigatorScrollViewLayout`): the line is left out rather than hidden, because a hidden
    /// view still takes part in Auto Layout.
    public static func makeForStackedNavigatorLayout() -> HorizontalSeparatorView? {
        if #available(macOS 26.0, *) {
            nil
        } else {
            HorizontalSeparatorView()
        }
    }
}

#endif
