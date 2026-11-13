import Foundation
import RuntimeViewerCore

/// What an editor pane's jump bar shows the path to: the step on screen in the pane's active tab
/// (proposal `editor-jump-bar`).
public enum EditorJumpBarLocation: Hashable, Sendable {
    /// An empty tab: the jump bar shows "No Selection".
    case nothing

    /// An image, by the path its image tree node gives, before any of its objects.
    case image(path: String)

    /// An object of an image.
    case object(RuntimeObject)

    /// Where the jump bar of a tab showing `entry` points; `nothing` for an empty tab.
    public init(entry: NavigationEntry?) {
        switch entry?.content {
        case .object(let object, _)?:
            self = .object(object)
        case .image(let path)?:
            self = .image(path: path)
        case nil:
            self = .nothing
        }
    }
}
