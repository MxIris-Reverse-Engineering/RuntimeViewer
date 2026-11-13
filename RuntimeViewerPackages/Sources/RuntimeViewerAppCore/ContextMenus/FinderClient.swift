import Foundation
import Dependencies
import DependenciesMacros
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

/// Shows a file in the Finder for the image list's Show in Finder.
///
/// A dependency for the same reason as `PasteboardClient`: the default test
/// value does nothing, so a test of the command opens no Finder window on the
/// machine it runs on.
public struct FinderClient: Sendable {
    public var revealFile: @MainActor @Sendable (URL) -> Void

    public init(revealFile: @escaping @MainActor @Sendable (URL) -> Void) {
        self.revealFile = revealFile
    }
}

extension FinderClient {
    /// Selects the file in a Finder window.
    public static let workspace = FinderClient { fileURL in
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        #endif
    }

    /// Shows nothing.
    public static let inert = FinderClient { _ in }
}

extension DependencyValues {
    @DependencyEntry(liveValue: FinderClient.workspace)
    public var finderClient = FinderClient.inert
}
