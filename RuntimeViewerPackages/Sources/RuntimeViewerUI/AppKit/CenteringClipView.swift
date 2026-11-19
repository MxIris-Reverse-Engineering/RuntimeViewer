#if os(macOS)

import AppKit

/// A clip view that centres its document view along any axis on which the
/// document is smaller than the clip view, where `NSClipView` pins it to the
/// top-left corner: a canvas zoomed out below the size of its scroll view
/// stays in the middle of it. Along an axis on which the document is larger,
/// it scrolls and clamps as `NSClipView` does.
///
/// The area around a centred document is the scroll view's background, so a
/// canvas that should not show an edge has the scroll view draw its own colour.
public final class CenteringClipView: NSClipView {
    public override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var constrainedBounds = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return constrainedBounds }
        let documentFrame = documentView.frame
        if constrainedBounds.width > documentFrame.width {
            constrainedBounds.origin.x = documentFrame.midX - constrainedBounds.width / 2
        }
        if constrainedBounds.height > documentFrame.height {
            constrainedBounds.origin.y = documentFrame.midY - constrainedBounds.height / 2
        }
        return constrainedBounds
    }
}

#endif
