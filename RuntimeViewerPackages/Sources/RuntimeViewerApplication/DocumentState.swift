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
    public private(set) var runtimeEngine: RuntimeEngine = .local

    /// Currently inspected runtime image. `nil` when the sidebar is at the
    /// image-picker root. Read-only externally: mutated only via the
    /// `.switchImage` route.
    @Observed
    public private(set) var currentImageNode: RuntimeImageNode?

    /// Navigation stack of runtime objects currently under inspection.
    ///
    /// - Empty: nothing selected (content / inspector show placeholder).
    /// - One element: root inspection of that object.
    /// - Multiple elements: user drilled into related objects from the
    ///   inspector relationships tab. The last element is the active
    ///   selection; preceding elements are ancestors on the back stack.
    ///
    /// Read-only externally: every mutation goes through `selectionRouter`,
    /// which dispatches a typed `SelectionRoute` and emits to
    /// `routeSignal` after the state update has been applied.
    @Observed
    public private(set) var selectionStack: [RuntimeObject] = []

    /// Top of `selectionStack` — the object currently shown by content /
    /// inspector. Mutations go through explicit selection routes
    /// (`selectAtRoot`, `drillInto`, `pop`, `clear`).
    public var selectedRuntimeObject: RuntimeObject? { selectionStack.last }

    /// Mutation surface for every observable state on this `DocumentState`.
    /// View models trigger routes on this router
    /// (`documentState.selectionRouter.trigger(.drillInto(x))`). The router
    /// applies the state mutation synchronously, then emits to
    /// `routeSignal` so scene-level subscribers (`MainCoordinator`) can
    /// fan out to their child coordinators.
    public private(set) lazy var selectionRouter: any Router<SelectionRoute> = SelectionRouter(documentState: self)

    /// Hot stream of selection routes. Emits **after** the corresponding
    /// state update on this `DocumentState` has been applied, so subscribers
    /// observe the post-mutation snapshot when handling a route. Hot —
    /// new subscribers do not see past routes.
    public var routeSignal: Signal<SelectionRoute> { routeRelay.asSignal() }

    private let routeRelay = PublishRelay<SelectionRoute>()

    fileprivate func apply(_ route: SelectionRoute) {
        switch route {
        case .switchEngine(let engine):
            if runtimeEngine === engine, currentImageNode == nil, selectionStack.isEmpty { return }
            runtimeEngine = engine
            currentImageNode = nil
            selectionStack = []
        case .switchImage(let node):
            if currentImageNode == node, selectionStack.isEmpty { return }
            currentImageNode = node
            selectionStack = []
        case .selectAtRoot(let object):
            selectionStack = [object]
        case .drillInto(let object):
            selectionStack.append(object)
        case .pop:
            guard !selectionStack.isEmpty else { return }
            selectionStack.removeLast()
        case .clear:
            guard !selectionStack.isEmpty else { return }
            selectionStack = []
        }
        routeRelay.accept(route)
    }

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

private final class SelectionRouter: Router {
    typealias Route = SelectionRoute

    private unowned let documentState: DocumentState

    init(documentState: DocumentState) {
        self.documentState = documentState
    }

    func contextTrigger(
        _ route: SelectionRoute,
        with options: TransitionOptions,
        completion: ContextPresentationHandler?
    ) {
        documentState.apply(route)
        completion?(EmptyRouteTransitionContext.shared)
    }
}

private struct EmptyRouteTransitionContext: TransitionContext {
    static let shared = EmptyRouteTransitionContext()
    var presentables: [any Presentable] { [] }
}
