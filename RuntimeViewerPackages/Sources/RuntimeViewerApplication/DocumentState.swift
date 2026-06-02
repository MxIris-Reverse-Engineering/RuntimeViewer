import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures

@MainActor
public final class DocumentState {
    public init() {}

    /// The runtime engine backing this Document. Read-only externally:
    /// mutated only via the `.switchEngine` route. `MainCoordinator` is
    /// responsible for issuing that route from its `.main` handler — the
    /// trigger also atomically clears `currentImageNode` and
    /// `selectionStack` so consumers never observe a half-switched state.
    ///
    /// `RuntimeBackgroundIndexingCoordinator` subscribes to `$runtimeEngine`
    /// and rewires its pumps onto the new engine's `backgroundIndexingManager`,
    /// cancelling the old engine's in-flight document batches as it goes.
    @Observed
    public fileprivate(set) var runtimeEngine: RuntimeEngine = .local

    /// Currently inspected runtime image. `nil` when the sidebar is at the
    /// image-picker root. Read-only externally: mutated only via the
    /// `.switchImage` route.
    @Observed
    public fileprivate(set) var currentImageNode: RuntimeImageNode?

    /// Navigation history of runtime objects under inspection. Behaves like
    /// a browser history list — `selectionIndex` is the cursor pointing at
    /// the currently shown element; `.pop` / `.forward` only move the
    /// cursor and leave the rest of the history in place so the user can
    /// step back and forth.
    ///
    /// - Empty: nothing selected (content / inspector show placeholder).
    /// - One element: cursor sits on the single entry (`.previous` /
    ///   `.forward` both no-ops).
    /// - Multiple elements with cursor mid-stack: the user navigated back
    ///   into earlier history and can still go forward to a later entry.
    ///
    /// `.push` from the cursor mid-stack truncates the forward portion
    /// first (browser-style) so a new branch overwrites the abandoned
    /// future.
    ///
    /// Read-only externally: every mutation goes through `selectionRouter`,
    /// which dispatches a typed `SelectionRoute` and emits to
    /// `routeSignal` after the state update has been applied.
    @Observed
    public fileprivate(set) var selectionStack: [RuntimeObject] = []

    /// Cursor into `selectionStack`. `-1` when the stack is empty;
    /// otherwise an index in `0..<selectionStack.count`. The element it
    /// points at is the active selection shown by content / inspector.
    @Observed
    public fileprivate(set) var selectionIndex: Int = -1

    /// Element at `selectionIndex` in `selectionStack`. `nil` when the
    /// stack is empty. Mutations go through explicit selection routes
    /// (`selectAtRoot`, `push`, `pop`, `forward`, `clear`).
    public var selectedRuntimeObject: RuntimeObject? {
        guard selectionIndex >= 0, selectionIndex < selectionStack.count else { return nil }
        return selectionStack[selectionIndex]
    }

    /// True when `.pop` (previous) would move the cursor to an earlier
    /// history entry. Drives toolbar previous-button enablement.
    public var canGoPrevious: Bool { selectionIndex > 0 }

    /// True when `.forward` (next) would move the cursor to a later
    /// history entry. Drives toolbar next-button enablement.
    public var canGoNext: Bool { selectionIndex < selectionStack.count - 1 }

    #if os(macOS)
    /// Mutation surface for every observable state on this `DocumentState`.
    /// View models trigger routes on this router
    /// (`documentState.selectionRouter.trigger(.drillInto(x))`). The router
    /// applies the state mutation synchronously, then emits to
    /// `routeSignal` so scene-level subscribers (`MainCoordinator`) can
    /// fan out to their child coordinators.
    public var selectionRouter: any Router<SelectionRoute> { _selectionRouter }

    /// Hot stream of selection routes. Emits **after** the corresponding
    /// state update on this `DocumentState` has been applied, so subscribers
    /// observe the post-mutation snapshot when handling a route. Hot —
    /// new subscribers do not see past routes.
    public var routeSignal: Signal<SelectionRoute> { _selectionRouter.routeRelay.asSignal() }

    private lazy var _selectionRouter = SelectionRouter(documentState: self)
    #endif

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

#if os(macOS)
private final class SelectionRouter: Router {
    typealias Route = SelectionRoute

    unowned let documentState: DocumentState

    let routeRelay = PublishRelay<SelectionRoute>()

    init(documentState: DocumentState) {
        self.documentState = documentState
    }

    func contextTrigger(
        _ route: SelectionRoute,
        with options: TransitionOptions,
        completion: ContextPresentationHandler?
    ) {
        switch route {
        case .switchEngine(let engine):
            if documentState.runtimeEngine === engine, documentState.currentImageNode == nil, documentState.selectionStack.isEmpty { return }
            documentState.runtimeEngine = engine
            documentState.currentImageNode = nil
            documentState.selectionStack = []
            documentState.selectionIndex = -1
        case .switchImage(let node):
            if documentState.currentImageNode == node, documentState.selectionStack.isEmpty { return }
            documentState.currentImageNode = node
            documentState.selectionStack = []
            documentState.selectionIndex = -1
        case .selectAtRoot(let object):
            documentState.selectionStack = [object]
            documentState.selectionIndex = 0
        case .push(let object):
            // Browser-style push: drop any forward history before
            // branching, so `.forward` after this never replays an entry
            // the user just abandoned.
            if documentState.selectionIndex < documentState.selectionStack.count - 1 {
                documentState.selectionStack = Array(documentState.selectionStack.prefix(documentState.selectionIndex + 1))
            }
            documentState.selectionStack.append(object)
            documentState.selectionIndex = documentState.selectionStack.count - 1
        case .pop:
            guard !documentState.selectionStack.isEmpty else { return }
            documentState.selectionStack.removeLast()
            // Clamp cursor back into the new bounds — if it was sitting
            // on the entry we just removed (or beyond), step it to the
            // new last; otherwise leave it where it was.
            if documentState.selectionStack.isEmpty {
                documentState.selectionIndex = -1
            } else if documentState.selectionIndex >= documentState.selectionStack.count {
                documentState.selectionIndex = documentState.selectionStack.count - 1
            }
        case .backward:
            guard documentState.selectionIndex > 0 else { return }
            documentState.selectionIndex -= 1
        case .forward:
            guard documentState.selectionIndex < documentState.selectionStack.count - 1 else { return }
            documentState.selectionIndex += 1
        case .clear:
            guard !documentState.selectionStack.isEmpty else { return }
            documentState.selectionStack = []
            documentState.selectionIndex = -1
        }
        routeRelay.accept(route)
        completion?(EmptyRouteTransitionContext.shared)
    }
}

private struct EmptyRouteTransitionContext: TransitionContext {
    static let shared = EmptyRouteTransitionContext()
    var presentables: [any Presentable] { [] }
}
#endif
