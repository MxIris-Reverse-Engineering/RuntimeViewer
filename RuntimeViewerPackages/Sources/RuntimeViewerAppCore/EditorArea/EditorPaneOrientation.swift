import Foundation

/// How the panes of one editor split sit next to each other.
public enum EditorPaneOrientation: Hashable, Sendable {
    /// Next to each other, divided by vertical lines.
    case sideBySide

    /// On top of each other, divided by horizontal lines.
    case stacked

    /// The other orientation: the one every child split of a layout runs in.
    public var opposite: EditorPaneOrientation {
        switch self {
        case .sideBySide: .stacked
        case .stacked: .sideBySide
        }
    }
}
