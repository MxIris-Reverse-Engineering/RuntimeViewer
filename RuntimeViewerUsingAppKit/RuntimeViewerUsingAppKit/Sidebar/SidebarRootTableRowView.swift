import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerUI

final class SidebarRootTableRowView: NSTableRowView {
    override var backgroundColor: NSColor {
        set {}
        get { Self.backgroundColor }
    }

    static let backgroundColor = NSColor.controlAccentColor.withSystemEffect(.deepPressed)
}
