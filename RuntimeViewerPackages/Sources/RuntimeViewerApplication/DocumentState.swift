import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures

@MainActor
public final class DocumentState {
    public init() {}

    /// The runtime engine backing this Document.
    ///
    /// Reassignable: `MainCoordinator` swaps this when the user changes source
    /// (Local ↔ XPC ↔ Bonjour). `RuntimeBackgroundIndexingCoordinator`
    /// subscribes to `$runtimeEngine` and rewires its pumps onto the new
    /// engine's `backgroundIndexingManager`, cancelling the old engine's
    /// in-flight document batches as it goes.
    @Observed
    public var runtimeEngine: RuntimeEngine = .local

    @Observed
    public var selectedRuntimeObject: RuntimeObject?

    @Observed
    public var currentImageNode: RuntimeImageNode?

    @Observed
    public var currentSubtitle: String = ""

    /// Per-Document background indexing coordinator. Created lazily on first
    /// access so that opening a Document does not pay the cost when the
    /// feature is disabled. The coordinator captures `runtimeEngine` at
    /// init — see the doc comment on that property.
    public private(set) lazy var backgroundIndexingCoordinator =
        RuntimeBackgroundIndexingCoordinator(documentState: self)
}
