import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures

@MainActor
public final class DocumentState {
    public init() {}

    /// The runtime engine backing this Document.
    ///
    /// Per Evolution 0002 (Background Indexing) Assumption #1, this property
    /// is treated as **immutable for the lifetime of the Document**. The
    /// declaration uses `@Observed public var` for historical reasons (early
    /// callers needed to swap in a remote engine after init), but current
    /// callers MUST NOT reassign it after the Document is opened.
    ///
    /// `RuntimeBackgroundIndexingCoordinator` (and any future per-engine
    /// actor) captures this reference at init time; reassignment would
    /// silently route work to a stale engine.
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
