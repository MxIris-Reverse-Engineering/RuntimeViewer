#if os(macOS)

import AppKit

/// A split view of the editor area, Xcode's `IDEEditorSplitView`: the thin divider style, 3 points
/// thick (`-[IDEEditorMultipleSplit loadView]`, IDEKit 27.2 0x13C3A0).
///
/// Xcode draws the divider in an opaque colour its editor theme computes for the appearance and for
/// whether the pane is active; the separator colour stands in for it.
public final class EditorSplitView: NSSplitView {
    public override var dividerThickness: CGFloat {
        3
    }

    public override var dividerColor: NSColor {
        .separatorColor
    }

    /// The top safe area the dividers were last drawn for. It moves with the toolbar — hidden, or
    /// gone in full screen — without the split view resizing, so nothing else redraws them.
    private var dividerTopSafeAreaInset: CGFloat = 0

    public override func layout() {
        super.layout()
        if safeAreaInsets.top != dividerTopSafeAreaInset {
            dividerTopSafeAreaInset = safeAreaInsets.top
            needsDisplay = true
        }
    }

    /// Draws a divider only below the split view's top safe area. The editor area runs under the
    /// toolbar, whose strip shows the panes' content blurred by the edge effect over it
    /// (`ToolbarScrollPocketContainerView`), and a divider drawn up through it split the toolbar.
    public override func drawDivider(in rect: NSRect) {
        let topSafeAreaInset = min(safeAreaInsets.top, bounds.height)
        var drawableRect = bounds
        drawableRect.size.height -= topSafeAreaInset
        if isFlipped {
            drawableRect.origin.y += topSafeAreaInset
        }
        let dividerRect = rect.intersection(drawableRect)
        guard !dividerRect.isEmpty else { return }
        super.drawDivider(in: dividerRect)
    }

    /// Draws the split view again when a pane comes or goes: the dividers it draws in its own layer come and go with
    /// them. With a delegate that constrains the dividers, as the editor area's does, `NSSplitView` does not do it by
    /// itself (measured on macOS 27.2), and the divider of a closed pane stayed in the layer — hidden behind the opaque
    /// content of the pane left beside it, but showing through an empty pane and through the scroll edge effects of
    /// the pane's bars, which replay what lies behind the pane, until a resize of the window redrew it.
    public override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        needsDisplay = true
    }

    public override func willRemoveSubview(_ subview: NSView) {
        super.willRemoveSubview(subview)
        needsDisplay = true
    }

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        dividerStyle = .thin
        arrangesAllSubviews = true
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

#endif
