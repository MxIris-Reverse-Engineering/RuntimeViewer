import Foundation
import Dependencies

/// Shows a file in the Finder for the image list's Show in Finder.
///
/// A dependency for the same reason as `PasteboardClient`: the default test
/// value does nothing, so a test of the command opens no Finder window on the
/// machine it runs on. The live value lives in RuntimeViewerAppUI, as
/// `PasteboardClient`'s does.
public struct FinderClient: Sendable {
    public var revealFile: @MainActor @Sendable (URL) -> Void

    public init(revealFile: @escaping @MainActor @Sendable (URL) -> Void) {
        self.revealFile = revealFile
    }
}

extension FinderClient {
    /// Shows nothing.
    public static let inert = FinderClient { _ in }
}

/// The Finder the image list's Show in Finder asks. RuntimeViewerAppUI gives it
/// its live value; a test gets `FinderClient.inert` unless it overrides it.
package enum FinderClientKey: TestDependencyKey {
    package static let testValue = FinderClient.inert
}

extension DependencyValues {
    package var finderClient: FinderClient {
        get { self[FinderClientKey.self] }
        set { self[FinderClientKey.self] = newValue }
    }
}
