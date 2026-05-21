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

    /// Navigation stack of runtime objects currently under inspection.
    ///
    /// - Empty: nothing selected (Content / Inspector show placeholder).
    /// - One element: root inspection of that object.
    /// - Multiple elements: user drilled into related objects from the Inspector
    ///   relationships tab. The last element is the active selection;
    ///   preceding elements are ancestors on the back stack.
    ///
    /// All UI panes (Sidebar visual selection, Content navigation stack,
    /// Inspector navigation stack) derive their state from this single
    /// source. Mutations enter through ViewModels / Coordinators that own
    /// user input (Sidebar row click, Inspector relationship click, Content
    /// back button, etc.).
    @Observed
    public var selectionStack: [RuntimeObject] = []

    /// Read-only derived view of `selectionStack.last`. Mutations go through
    /// explicit `selectionStack` operations (push / pop / reset / append).
    public var selectedRuntimeObject: RuntimeObject? { selectionStack.last }

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
