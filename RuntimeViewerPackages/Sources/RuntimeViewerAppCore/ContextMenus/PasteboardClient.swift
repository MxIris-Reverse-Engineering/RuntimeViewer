import Foundation
import Dependencies

/// Puts text on the pasteboard for the context menus' copy commands.
///
/// A dependency rather than a call to the general pasteboard so that a test
/// reads what a copy command wrote from a client of its own: the default test
/// value does nothing, and the general pasteboard is the user's — a test run
/// that wrote to it would replace whatever they had copied.
///
/// The live value, the system's general pasteboard, lives in RuntimeViewerAppUI,
/// which adds the `DependencyKey` conformance: reaching the pasteboard takes
/// AppKit or UIKit, which this module does not use (proposal
/// `app-core-without-ui-models`).
public struct PasteboardClient: Sendable {
    public var copyString: @MainActor @Sendable (String) -> Void

    public init(copyString: @escaping @MainActor @Sendable (String) -> Void) {
        self.copyString = copyString
    }
}

extension PasteboardClient {
    /// Copies nothing.
    public static let inert = PasteboardClient { _ in }
}

/// The pasteboard the copy commands write to. RuntimeViewerAppUI gives it its
/// live value; a test gets `PasteboardClient.inert` unless it overrides it.
package enum PasteboardClientKey: TestDependencyKey {
    package static let testValue = PasteboardClient.inert
}

extension DependencyValues {
    package var pasteboardClient: PasteboardClient {
        get { self[PasteboardClientKey.self] }
        set { self[PasteboardClientKey.self] = newValue }
    }
}
