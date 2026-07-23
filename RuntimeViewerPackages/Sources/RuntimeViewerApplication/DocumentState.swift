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

    /// Document-level navigation timeline, Xcode-style: one entry per
    /// object the user has viewed, regardless of how it was reached —
    /// sidebar click, content link, "Open in New Tab", or switching to a
    /// tab already showing it. `selectionIndex` is the cursor; `.backward`
    /// / `.forward` only move the cursor and leave the entries in place so
    /// the user can step back and forth.
    ///
    /// Any navigation away from a mid-timeline cursor position (`.push`,
    /// a tab switch, `.openInNewTab`, `.newTab`) truncates the forward
    /// portion first (browser-style) so a new branch overwrites the
    /// abandoned future. Consecutive duplicates are collapsed: reaching
    /// the object already at the top only moves the cursor.
    ///
    /// The timeline is deliberately independent of the tab strip: it
    /// survives tab switches and closes, and it may retain objects whose
    /// tab is long gone.
    ///
    /// Read-only externally: every mutation goes through `selectionRouter`,
    /// which dispatches a typed `SelectionRoute` and emits to
    /// `routeSignal` after the state update has been applied.
    @Observed
    public fileprivate(set) var selectionStack: [RuntimeObject] = []

    /// Cursor into `selectionStack`. `-1` when the stack is empty;
    /// otherwise an index in `0..<selectionStack.count`. After every route
    /// except `.newTab` it points at the entry `selectedRuntimeObject`
    /// shows; on an empty tab the cursor keeps its position (the most
    /// recently viewed entry) while `selectedRuntimeObject` is `nil`, so
    /// the first `.backward` can return to it.
    @Observed
    public fileprivate(set) var selectionIndex: Int = -1

    /// The object the content / inspector panes are showing, or `nil` for
    /// the placeholder (empty tab). This is the display layer's single
    /// source of truth: navigation routes set it from the timeline cursor,
    /// tab routes set it from the target tab's `object`. Read-only
    /// externally: mutated only via `selectionRouter`.
    @Observed
    public fileprivate(set) var selectedRuntimeObject: RuntimeObject?

    /// Content-pane tabs. Tabs and the navigation timeline are independent
    /// mechanisms: a tab is a display slot holding one `object`, while the
    /// timeline records viewing order across all of them. The active tab's
    /// `object` mirrors `selectedRuntimeObject` (the router writes
    /// navigation through to it, so back/forward land in the active tab);
    /// inactive tabs hold a frozen object. There is always at least one
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

    /// True when `.backward` would land somewhere: either the cursor has
    /// an earlier entry, or the pane shows the placeholder (empty tab)
    /// while the timeline still holds the most recently viewed entry —
    /// the first `.backward` then returns to the cursor itself. Drives
    /// toolbar previous-button enablement.
    public var canGoPrevious: Bool {
        if selectedRuntimeObject == nil, selectionIndex >= 0 { return true }
        return selectionIndex > 0
    }

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
            resetHistory()
            // Engine switch resets the whole document: collapse back to a
            // single empty tab.
            documentState.tabs = [DocumentTab()]
            documentState.activeTabIndex = 0
        case .switchImage(let node):
            if documentState.currentImageNode == node, documentState.selectionStack.isEmpty { return }
            documentState.currentImageNode = node
            resetHistory()
            // Tabs hold objects belonging to the current image; switching the
            // inspected image is a fresh browsing context, so collapse back to
            // a single empty tab (mirrors `.switchEngine`). Cross-image tab
            // persistence is a possible later enhancement.
            documentState.tabs = [DocumentTab()]
            documentState.activeTabIndex = 0
        case .selectAtRoot(let object):
            documentState.selectionStack = [object]
            documentState.selectionIndex = 0
            documentState.selectedRuntimeObject = object
        case .push(let object):
            pushOntoTimeline(object)
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
            syncSelectionFromCursor()
        case .backward:
            if documentState.selectedRuntimeObject == nil, cursorObject() != nil {
                // Empty tab over a non-empty timeline: the first step back
                // returns to the cursor itself (the most recently viewed
                // entry) rather than skipping past it.
                syncSelectionFromCursor()
            } else {
                guard documentState.selectionIndex > 0 else { return }
                documentState.selectionIndex -= 1
                syncSelectionFromCursor()
            }
        case .forward:
            guard documentState.selectionIndex < documentState.selectionStack.count - 1 else { return }
            documentState.selectionIndex += 1
            syncSelectionFromCursor()
        case .jump(let toIndex):
            // The same-index jump is allowed when the pane shows the
            // placeholder (empty tab): it restores the cursor entry.
            guard toIndex >= 0,
                  toIndex < documentState.selectionStack.count,
                  toIndex != documentState.selectionIndex || documentState.selectedRuntimeObject == nil
            else { return }
            documentState.selectionIndex = toIndex
            syncSelectionFromCursor()
        case .clear:
            guard !documentState.selectionStack.isEmpty else { return }
            resetHistory()
        case .newTab:
            // The timeline survives; only the forward branch is abandoned,
            // exactly as for a tab switch. The cursor stays on the most
            // recently viewed entry so `.backward` can return to it.
            truncateForwardBranch()
            documentState.tabs.append(DocumentTab())
            documentState.activeTabIndex = documentState.tabs.count - 1
            documentState.selectedRuntimeObject = nil
        case .openInNewTab(let object):
            documentState.tabs.append(DocumentTab(object: object))
            documentState.activeTabIndex = documentState.tabs.count - 1
            pushOntoTimeline(object)
        case .switchTab(let index):
            guard index >= 0, index < documentState.tabs.count, index != documentState.activeTabIndex else { return }
            documentState.activeTabIndex = index
            rejoinTimeline(with: documentState.tabs[index].object)
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
                rejoinTimeline(with: documentState.tabs[newActiveIndex].object)
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
        // `selectedRuntimeObject` — this is what makes back/forward land in
        // the active tab. The tab-management cases above already set both
        // sides consistently; the guard makes the write a no-op for them and
        // suppresses redundant `tabs` emissions on plain navigation.
        syncActiveTabObject()
        routeRelay.accept(route)
        completion?(EmptyRouteTransitionContext.shared)
    }

    /// Entry at the timeline cursor, or `nil` when the timeline is empty.
    private func cursorObject() -> RuntimeObject? {
        guard documentState.selectionIndex >= 0,
              documentState.selectionIndex < documentState.selectionStack.count
        else { return nil }
        return documentState.selectionStack[documentState.selectionIndex]
    }

    /// Sets `selectedRuntimeObject` from the timeline cursor. Every
    /// navigation route ends here so the panes follow the cursor.
    private func syncSelectionFromCursor() {
        documentState.selectedRuntimeObject = cursorObject()
    }

    /// Drops the abandoned forward branch: entries after the cursor are
    /// unreachable once the user navigates somewhere new from a
    /// mid-timeline position (browser-style).
    private func truncateForwardBranch() {
        guard documentState.selectionIndex < documentState.selectionStack.count - 1 else { return }
        documentState.selectionStack = Array(documentState.selectionStack.prefix(documentState.selectionIndex + 1))
    }

    /// Records viewing `object` on the timeline: truncates the forward
    /// branch, appends the entry unless it already sits at the top
    /// (consecutive duplicates only move the cursor), and shows it.
    private func pushOntoTimeline(_ object: RuntimeObject) {
        truncateForwardBranch()
        if documentState.selectionStack.last != object {
            documentState.selectionStack.append(object)
        }
        documentState.selectionIndex = documentState.selectionStack.count - 1
        documentState.selectedRuntimeObject = object
    }

    /// Re-enters the timeline after a tab switch / close: the target tab's
    /// object is recorded like any other navigation (Xcode-style — back
    /// steps through everything viewed, however it was reached), or, for an
    /// empty tab, only the forward branch is dropped and the placeholder
    /// shows while the cursor keeps the most recently viewed entry.
    private func rejoinTimeline(with object: RuntimeObject?) {
        if let object {
            pushOntoTimeline(object)
        } else {
            truncateForwardBranch()
            documentState.selectedRuntimeObject = nil
        }
    }

    /// Empties the timeline and shows the placeholder. Used when the
    /// browsing context itself changes (engine / image switch, `.clear`).
    private func resetHistory() {
        documentState.selectionStack = []
        documentState.selectionIndex = -1
        documentState.selectedRuntimeObject = nil
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
