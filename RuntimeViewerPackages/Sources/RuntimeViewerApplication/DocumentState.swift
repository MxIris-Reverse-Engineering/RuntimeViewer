import Foundation
import Observation
import RuntimeViewerCore
import RuntimeViewerArchitectures
#if canImport(UIKit)
import UIKit
#endif

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

    /// Content-pane tabs. Every tab shares the one document-level navigation
    /// history above; the active tab's `object` mirrors
    /// `selectedRuntimeObject` (the router writes navigation through to it),
    /// while inactive tabs hold a frozen object. There is always at least one
    /// tab. Read-only externally: mutated only via the tab selection routes
    /// (`newTab`, `openInNewTab`, `switchTab`, `closeTab`, `moveTab`) and the
    /// active-tab write-through applied after every history mutation.
    @Observed
    public fileprivate(set) var tabs: [DocumentTab] = [DocumentTab()]

    /// Index of the active tab in `tabs`. Always a valid index (there is
    /// always at least one tab).
    @Observed
    public fileprivate(set) var activeTabIndex: Int = 0

    /// The active tab, or `nil` only in the degenerate empty-`tabs` state
    /// (which the router never produces).
    public var activeTab: DocumentTab? {
        guard activeTabIndex >= 0, activeTabIndex < tabs.count else { return nil }
        return tabs[activeTabIndex]
    }

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

    /// Mutation surface for every observable state on this `DocumentState`.
    /// View models trigger routes on this router
    /// (`documentState.selectionRouter.trigger(.push(x))`). The router
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
    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    typealias Route = SelectionRoute
    #else
    typealias RouteType = SelectionRoute
    #endif

    unowned let documentState: DocumentState

    let routeRelay = PublishRelay<SelectionRoute>()

    init(documentState: DocumentState) {
        self.documentState = documentState
    }

    #if canImport(UIKit) && !targetEnvironment(macCatalyst) && !os(macOS)
    // XCoordinator's `Router` extends `Presentable`. `SelectionRouter` does
    // not own a view controller — it exists solely to mutate state and emit
    // routes — so the Presentable surface is a deliberate no-op.
    var viewController: UIViewController! { nil }
    func router<R: Route>(for route: R) -> (any Router<R>)? { nil }
    #endif

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
            // Engine switch resets the whole document: collapse back to a
            // single empty tab.
            documentState.tabs = [DocumentTab()]
            documentState.activeTabIndex = 0
        case .switchImage(let node):
            if documentState.currentImageNode == node, documentState.selectionStack.isEmpty { return }
            documentState.currentImageNode = node
            documentState.selectionStack = []
            documentState.selectionIndex = -1
            // Tabs hold objects belonging to the current image; switching the
            // inspected image is a fresh browsing context, so collapse back to
            // a single empty tab (mirrors `.switchEngine`). Cross-image tab
            // persistence is a possible later enhancement.
            documentState.tabs = [DocumentTab()]
            documentState.activeTabIndex = 0
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
        case .jump(let toIndex):
            guard toIndex >= 0,
                  toIndex < documentState.selectionStack.count,
                  toIndex != documentState.selectionIndex
            else { return }
            documentState.selectionIndex = toIndex
        case .clear:
            guard !documentState.selectionStack.isEmpty else { return }
            documentState.selectionStack = []
            documentState.selectionIndex = -1
        case .newTab:
            documentState.tabs.append(DocumentTab())
            documentState.activeTabIndex = documentState.tabs.count - 1
            documentState.selectionStack = []
            documentState.selectionIndex = -1
        case .openInNewTab(let object):
            documentState.tabs.append(DocumentTab(object: object))
            documentState.activeTabIndex = documentState.tabs.count - 1
            documentState.selectionStack = [object]
            documentState.selectionIndex = 0
        case .switchTab(let index):
            guard index >= 0, index < documentState.tabs.count, index != documentState.activeTabIndex else { return }
            documentState.activeTabIndex = index
            rebindHistory(to: documentState.tabs[index].object)
        case .closeTab(let index):
            // The last remaining tab is never closed here — the menu layer
            // turns ⌘W into "close window" in that state.
            guard documentState.tabs.count > 1, index >= 0, index < documentState.tabs.count else { return }
            let wasActive = index == documentState.activeTabIndex
            documentState.tabs.remove(at: index)
            if wasActive {
                // Activate the right neighbour (same index after removal), or
                // the left one when the closed tab was last.
                let newActiveIndex = min(index, documentState.tabs.count - 1)
                documentState.activeTabIndex = newActiveIndex
                rebindHistory(to: documentState.tabs[newActiveIndex].object)
            } else if index < documentState.activeTabIndex {
                documentState.activeTabIndex -= 1
            }
        case .moveTab(let from, let to):
            guard from >= 0, from < documentState.tabs.count,
                  to >= 0, to < documentState.tabs.count,
                  from != to
            else { return }
            let activeID = documentState.activeTab?.id
            let moved = documentState.tabs.remove(at: from)
            documentState.tabs.insert(moved, at: to)
            if let activeID, let newActiveIndex = documentState.tabs.firstIndex(where: { $0.id == activeID }) {
                documentState.activeTabIndex = newActiveIndex
            }
        }
        // Keep the active tab's object in step with the (possibly mutated)
        // navigation cursor. The tab-management cases above already set both
        // sides consistently; the guard makes the write a no-op for them and
        // suppresses redundant `tabs` emissions on plain navigation.
        syncActiveTabObject()
        routeRelay.accept(route)
        completion?(EmptyRouteTransitionContext.shared)
    }

    /// Resets the shared navigation history to show a single object (or the
    /// placeholder for `nil`). Used when switching to / closing a tab.
    private func rebindHistory(to object: RuntimeObject?) {
        if let object {
            documentState.selectionStack = [object]
            documentState.selectionIndex = 0
        } else {
            documentState.selectionStack = []
            documentState.selectionIndex = -1
        }
    }

    /// Writes the current `selectedRuntimeObject` through to the active tab, so
    /// the active tab's title tracks navigation. No-op (no emission) when the
    /// object is already in sync.
    private func syncActiveTabObject() {
        let index = documentState.activeTabIndex
        guard index >= 0, index < documentState.tabs.count else { return }
        let currentObject = documentState.selectedRuntimeObject
        guard documentState.tabs[index].object != currentObject else { return }
        documentState.tabs[index].object = currentObject
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
private struct EmptyRouteTransitionContext: TransitionContext {
    static let shared = EmptyRouteTransitionContext()
    var presentables: [any Presentable] { [] }
}
#elseif canImport(UIKit)
private struct EmptyRouteTransitionContext: TransitionProtocol {
    typealias RootViewController = UIViewController
    static let shared = EmptyRouteTransitionContext()

    var presentables: [Presentable] { [] }
    var animation: TransitionAnimation? { nil }

    func perform(on rootViewController: UIViewController, with options: TransitionOptions, completion: PresentationHandler?) {
        completion?()
    }

    static func multiple(_ transitions: [EmptyRouteTransitionContext]) -> EmptyRouteTransitionContext { .shared }
}
#endif
