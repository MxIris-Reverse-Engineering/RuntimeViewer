import Foundation

/// Where a new editor pane goes, relative to the pane it is made from: File ▸ New Editor Pane On
/// Right and Below, as Xcode names them.
public enum EditorPanePlacement: Hashable, Sendable {
    case onRight
    case below

    /// The orientation a split needs to hold the new pane beside the one it is made from.
    var orientation: EditorPaneOrientation {
        switch self {
        case .onRight: .sideBySide
        case .below: .stacked
        }
    }
}
