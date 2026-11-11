import Foundation

/// A command the image list's context menu offers on an image, on either of
/// its pages (the directory and the bookmarks). Which ones an image offers is
/// `SidebarRootViewModel.imageActions(for:)`.
public enum RuntimeImageAction: Hashable, Sendable {
    /// Opens the image, as a double-click does.
    case open

    /// Find in This Image…: the Find navigator, its scope narrowed to the
    /// image, waiting for a query.
    case findInImage

    /// Puts the image's name on the pasteboard.
    case copyName

    /// Puts the image's path on the pasteboard.
    case copyPath

    /// Selects the image's file in the Finder.
    case showInFinder
}
