import Foundation
import Dependencies
import RuntimeViewerAppCore
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

extension FinderClient {
    /// Selects the file in a Finder window; does nothing where there is no Finder.
    public static let workspace = FinderClient { fileURL in
        #if canImport(AppKit) && !targetEnvironment(macCatalyst)
        NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        #endif
    }
}

/// The live value of RuntimeViewerAppCore's `finderClient`, which declares only the interface and the
/// value tests get.
extension FinderClientKey: DependencyKey {
    package static let liveValue = FinderClient.workspace
}
