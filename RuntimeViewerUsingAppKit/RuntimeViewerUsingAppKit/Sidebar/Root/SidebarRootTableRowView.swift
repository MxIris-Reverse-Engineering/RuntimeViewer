import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerUI

final class SidebarRootTableRowView: TableRowView {
    override var backgroundColor: NSColor {
        set {}
        get { Self.backgroundColor }
    }
    
    private static let backgroundColor = NSColor.controlAccentColor.withSystemEffect(.deepPressed)
}
