import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerUI

final class SidebarRootTableRowView: NSTableRowView {
    override var backgroundColor: NSColor {
        set {}
        get { Self.backgroundColor }
    }

    override var interiorBackgroundStyle: NSView.BackgroundStyle {
        set {}
        get { .emphasized }
    }
    
    private static let backgroundColor = NSColor.controlAccentColor.withSystemEffect(.deepPressed)
}
