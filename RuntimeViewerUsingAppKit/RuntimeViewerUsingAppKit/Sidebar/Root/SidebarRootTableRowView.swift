import AppKit
import RuntimeViewerApplication
import RuntimeViewerArchitectures
import RuntimeViewerUI

final class SidebarTableRowView: TableRowView {
    override var backgroundColor: NSColor {
        set {}
        get { isEmphasized ? Self.backgroundColor : .disabledControlTextColor }
    }
    
    private static let backgroundColor = NSColor.controlAccentColor.withSystemEffect(.deepPressed)
}
