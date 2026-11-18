#if os(macOS)

import AppKit

/// The text view of the content pane: a link is followed by the pane itself, never by AppKit, and
/// nothing can be dragged into it.
public final class ContentTextView: NSTextView {
    public override func clicked(onLink link: Any, at charIndex: Int) {}
    public override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
}

#endif
