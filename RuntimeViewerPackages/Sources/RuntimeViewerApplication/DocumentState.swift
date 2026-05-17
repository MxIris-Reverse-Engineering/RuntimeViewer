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
    
    /// Per-Document background indexing coordinator.
    ///
    /// Force-initialized on the first Document lifecycle hook
    /// (`makeWindowControllers` / `close`) and kept alive for the rest of
    /// the Document's lifetime, even when the feature is disabled at open
    /// time, so it can react to settings off→on toggles. The `lazy`
    /// modifier is retained as an init-deferral mechanism, not as a
    /// gating-by-enablement: every opened Document instantiates one
    /// coordinator regardless of `Settings.Indexing.BackgroundMode.isEnabled`.
    ///
    /// The coordinator captures `runtimeEngine` initially and rewires onto
    /// a new engine via the `$runtimeEngine` subscription on every source
    /// switch — see that property's doc comment for the swap contract.
    public private(set) lazy var backgroundIndexingCoordinator = RuntimeBackgroundIndexingCoordinator(documentState: self)
}
