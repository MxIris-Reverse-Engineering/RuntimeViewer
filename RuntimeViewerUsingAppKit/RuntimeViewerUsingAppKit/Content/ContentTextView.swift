import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

class ContentTextView: NSTextView {
    override func clicked(onLink link: Any, at charIndex: Int) {}
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [] }
}
