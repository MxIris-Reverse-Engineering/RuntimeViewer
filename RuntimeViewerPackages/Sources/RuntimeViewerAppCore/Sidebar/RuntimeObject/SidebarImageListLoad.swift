import Foundation
import RuntimeViewerCore

/// Where the sidebar's object list of the image the sidebar is in stands, as the list reports it
/// (`DocumentState.sidebarImageListLoad`). What lists objects of that image apart from the list —
/// the image's bookmarks page and the start page's recent objects — shows the list's loading page
/// while the list shows its own, so that nothing of an image can be opened from them before the
/// list has loaded it.
public struct SidebarImageListLoad: Sendable {
    public enum Phase: Sendable {
        /// The list shows its loading page, or has not decided yet what it shows: the progress of
        /// the build under way, `nil` until the build reports any.
        case loading(RuntimeObjectsLoadingProgress?)
        /// The list shows what it came to: its objects, that the image is not loaded, or why it
        /// could not be loaded.
        case settled

        public var isSettled: Bool {
            guard case .settled = self else { return false }
            return true
        }

        /// What an `ImageIndexingProgressView` shows for this phase: the progress under way,
        /// `ImageIndexingProgress.preparing` until there is one.
        public var indexingProgress: ImageIndexingProgress {
            guard case .loading(let progress?) = self else { return .preparing }
            return ImageIndexingProgress(progress)
        }
    }

    /// The path of the sidebar's image node, which `currentImageNode` carries.
    public let imagePath: String

    public let phase: Phase

    public init(imagePath: String, phase: Phase) {
        self.imagePath = imagePath
        self.phase = phase
    }
}

/// The right of one sidebar object list to report on its image to the document
/// (`DocumentState.makeSidebarImageListLoadReporter(forImageAt:)`). Only the reporter made last for
/// the image the sidebar is in is heard: a list made for an earlier visit to the same image can
/// still be loading, and its end must not end the wait for the list on screen.
@MainActor
public final class SidebarImageListLoadReporter {
    public let imagePath: String

    private weak var documentState: DocumentState?

    init(imagePath: String, documentState: DocumentState) {
        self.imagePath = imagePath
        self.documentState = documentState
    }

    public func report(_ phase: SidebarImageListLoad.Phase) {
        documentState?.receiveSidebarImageListLoad(phase, from: self)
    }
}
