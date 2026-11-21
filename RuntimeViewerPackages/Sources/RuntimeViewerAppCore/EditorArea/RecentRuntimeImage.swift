import Foundation
import RuntimeViewerCore

/// An image an engine's windows worked in, and the objects of it their editor panes showed: one
/// entry of an engine's list in `AppDefaults.recentRuntimeImagesByEngine`, which an empty editor
/// pane's start page lists (proposal `editor-start-page`). Read and written through
/// `RecentRuntimeImages`.
public struct RecentRuntimeImage: Codable, Hashable, Sendable {
    /// The image's path in the form `RuntimeEngine.canonicalImagePath(_:)` gives — the form every
    /// `RuntimeObject.imagePath` carries — so the sidebar's spelling of a path and an object's
    /// name one image.
    public let imagePath: String

    /// The objects of the image the editor panes showed, most recent first, each without its
    /// `children` (`RecentRuntimeImages.listedForm(of:)`).
    public let objects: [RuntimeObject]

    public init(imagePath: String, objects: [RuntimeObject] = []) {
        self.imagePath = imagePath
        self.objects = objects
    }
}
