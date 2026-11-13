import Foundation
import RuntimeViewerCore

/// What the user chose in an editor pane's jump bar, and where to show it.
public struct EditorJumpBarChoice: Hashable, Sendable {
    /// What was chosen.
    public enum Target: Hashable, Sendable {
        /// An image, by its image tree path: shown before any of its objects, indexed first when
        /// it is not.
        case image(path: String)

        /// An object of an image.
        case object(RuntimeObject)
    }

    public let target: Target

    /// The focused tab, a new tab or the next pane, from the modifier keys held while choosing.
    public let destination: SelectionRoute.Destination

    public init(target: Target, destination: SelectionRoute.Destination) {
        self.target = target
        self.destination = destination
    }

    /// The route that shows the choice.
    public var route: SelectionRoute {
        switch target {
        case .image(let path):
            .openImage(path, in: destination)
        case .object(let object):
            .open(object, in: destination)
        }
    }
}
