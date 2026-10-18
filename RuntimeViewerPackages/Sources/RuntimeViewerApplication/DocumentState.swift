import Foundation
import Combine
import Dependencies
import Observation
import RuntimeViewerCore
import RuntimeViewerCrossReferences
import RuntimeViewerArchitectures
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class DocumentState {
    /// - Parameter runtimeEngine: The engine the document opens on. The app
    ///   passes its manager's "My Mac" engine; the default is the in-process
    ///   engine, for tests and for platforms without an engine manager.
    public init(runtimeEngine: RuntimeEngine = .local) {
        self.runtimeEngine = runtimeEngine
        observeReadiness(of: runtimeEngine)
    }

    /// The runtime engine backing this Document. Read-only externally:
    /// mutated only via the `.switchEngine` route. `MainCoordinator` is
    /// responsible for issuing that route from its `.main` handler — the
    /// trigger also atomically clears `currentImageNode` and
    /// `selectionStack` so consumers never observe a half-switched state.
    ///
    /// The route moves the document onto the new engine's background work
    /// before it assigns the engine, so whatever follows `$runtimeEngine`
    /// finds the new engine's coordinators; see `backgroundIndexingCoordinator`.
    @RxObserved
    public fileprivate(set) var runtimeEngine: RuntimeEngine

    /// Subscription to the current engine's readiness; see ``observeReadiness(of:)``.
    private var engineReadinessSubscription: AnyCancellable?

    /// Whether the current engine was ready at the last readiness event, so
    /// a `false → true` edge can be told apart from the replayed current state.
    private var engineWasReady = false

    /// Fires with the document's engine each time the document starts over on
    /// it: the `.switchEngine` route put an engine in place — another one, or
    /// the same one after the process behind it came back — or the engine
    /// came back while the document had nothing open, which leaves the route
    /// nothing to walk back (see `observeReadiness(of:)`). Whatever was
    /// learned from the process behind the engine is stale by then: its
    /// corpora, the searches run on it, the builds it was running.
    ///
    /// `$runtimeEngine` does not cover the second case: nothing is assigned
    /// when nothing is open.
    public var runtimeEngineDidReset: Signal<RuntimeEngine> {
        runtimeEngineDidResetRelay.asSignal()
    }

    fileprivate let runtimeEngineDidResetRelay = PublishRelay<RuntimeEngine>()

    /// The sidebar at the image list and nothing on the timeline: an engine
    /// coming back has nothing to walk the document back from.
    fileprivate var hasNothingOpen: Bool {
        currentImageNode == nil && selectionStack.isEmpty
    }

    /// Walks the document back to the image list when its engine stops being
    /// ready and then becomes ready again.
    ///
    /// That edge is the local-runtime XPC service having been relaunched:
    /// the engine object survives, but the process behind it is new and holds
    /// none of the images this document was browsing, so every request from
    /// where the user stands would fail. The `.switchEngine` route onto the
    /// same engine is the existing "start over on this engine" reset. With
    /// nothing open it would be a no-op, so the edge then only announces the
    /// reset (`runtimeEngineDidReset`) — the engine's very first connection
    /// included, which is no different from a reset as far as anything that
    /// asked the engine before is concerned.
    ///
    /// Keyed on `isReady`, not on a particular state: an in-process engine
    /// goes `.localOnly` rather than `.connected`, and a test can drive the
    /// same edge with `stop()` followed by `connect()`.
    fileprivate func observeReadiness(of engine: RuntimeEngine) {
        engineWasReady = engine.state.isReady
        engineReadinessSubscription = engine.statePublisher
            .map(\.isReady)
            .sink { [weak self, weak engine] isReady in
                Task { @MainActor [weak self, weak engine] in
                    guard let self, let engine else { return }
                    self.handleReadinessChange(isReady, of: engine)
                }
            }
    }

    private func handleReadinessChange(_ isReady: Bool, of engine: RuntimeEngine) {
        guard engine === runtimeEngine else { return }
        let becameReadyAgain = isReady && !engineWasReady
        engineWasReady = isReady
        guard becameReadyAgain else { return }
        if hasNothingOpen {
            runtimeEngineDidResetRelay.accept(engine)
        } else {
            selectionRouter.trigger(.switchEngine(engine))
        }
    }

    /// Currently inspected runtime image. `nil` when the sidebar is at the
    /// image-picker root. Read-only externally: mutated only via the
    /// `.switchImage` route.
    @RxObserved
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
    /// the type already at the top only moves the cursor, though the entry
    /// takes on the form just reached when that form differs.
    ///
    /// The timeline is deliberately independent of the tab strip: it
    /// survives tab switches and closes, and it may retain objects whose
    /// tab is long gone.
    ///
    /// Read-only externally: every mutation goes through `selectionRouter`,
    /// which dispatches a typed `SelectionRoute` and emits to
    /// `routeSignal` after the state update has been applied.
    @RxObserved
    public fileprivate(set) var selectionStack: [RuntimeObject] = []

    /// Cursor into `selectionStack`. `-1` when the stack is empty;
    /// otherwise an index in `0..<selectionStack.count`. After every route
    /// except `.newTab` it points at the entry `selectedRuntimeObject`
    /// shows; on an empty tab the cursor keeps its position (the most
    /// recently viewed entry) while `selectedRuntimeObject` is `nil`, so
    /// the first `.backward` can return to it.
    @RxObserved
    public fileprivate(set) var selectionIndex: Int = -1

    /// The object the content / inspector panes are showing, or `nil` for
    /// the placeholder (empty tab). This is the display layer's single
    /// source of truth: navigation routes set it from the timeline cursor,
    /// tab routes set it from the target tab's `object`. Read-only
    /// externally: mutated only via `selectionRouter`.
    @RxObserved
    public fileprivate(set) var selectedRuntimeObject: RuntimeObject?

    /// The member whose declaration the content pane's insertion point is on,
    /// or `nil` when the point is on no member's line. The Inspector's
    /// References tab follows it, and Find Call Hierarchy in the main menu acts
    /// on it, as Xcode's acts on the symbol at the insertion point. Set by the
    /// content pane, which reads which line declares which member
    /// (`RuntimeObjectInterface.declaredMembersByLineNumber()`); a member of
    /// another object than the one on screen does not count.
    @RxObserved
    public private(set) var cursorMember: RuntimeMemberReference?

    public func updateCursorMember(_ member: RuntimeMemberReference?) {
        guard member != cursorMember else { return }
        cursorMember = member
    }

    /// Content-pane tabs. Tabs and the navigation timeline are independent
    /// mechanisms: a tab is a display slot holding one `object`, while the
    /// timeline records viewing order across all of them. The active tab's
    /// `object` mirrors `selectedRuntimeObject` (the router writes
    /// navigation through to it, so back/forward land in the active tab);
    /// inactive tabs hold a frozen object. There is always at least one
    /// tab. Read-only externally: mutated only via the tab selection routes
    /// (`newTab`, `openInNewTab`, `switchTab`, `closeTab`, `moveTab`) and the
    /// active-tab write-through applied after every history mutation.
    @RxObserved
    public fileprivate(set) var tabs: [DocumentTab] = [DocumentTab()]

    /// Index of the active tab in `tabs`. Always a valid index (there is
    /// always at least one tab).
    @RxObserved
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

    /// True when the object on screen belongs to the image the sidebar lists
    /// (`currentImageNode`), the only image whose rows the sidebar holds.
    /// False on an empty tab and at the image-list root, and after a content
    /// link or an Inspector relationship reaches an object in another image —
    /// those push the object without moving the sidebar. Drives the enablement
    /// of Navigate ▸ Reveal in Sidebar Navigator.
    public var isSelectedRuntimeObjectInCurrentImage: Bool {
        guard let selectedRuntimeObject, let currentImageNode else { return false }
        // An object's image path is the engine's key; a sidebar node's is
        // not, on an iOS Simulator engine.
        return selectedRuntimeObject.imagePath == runtimeEngine.canonicalImagePath(currentImageNode.path)
    }

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

    @Dependency(\.runtimeEngineBackgroundWorkRegistry)
    private var backgroundWorkRegistry

    /// The background work of the engine the document is on — its indexing
    /// coordinator and its corpus coordinator — which every document on the
    /// engine shares, so the documents on one engine show one Report. Joined
    /// when the document first needs either coordinator, then carried onto
    /// each engine the document moves to; `nil` until then. Once the document
    /// has closed, the work it left, so a late reader finds the coordinators
    /// it read before rather than joining the engine again.
    private var backgroundWork: RuntimeEngineBackgroundWork?

    /// The document has needed its engine's background indexing: the engine it
    /// moves to gets its own started too, as opening started this one's.
    private var needsBackgroundIndexing = false

    /// The document has needed its engine's interface corpus: its Find session
    /// and its sidebar's image follow that engine's corpus coordinator, and the
    /// engine it moves to gets one too.
    private var needsInterfaceCorpus = false

    /// The document has needed its engine's prepared cross references: the
    /// engine it moves to gets its preparation started too.
    private var needsCrossReferencePreparation = false

    /// `documentWillClose()` has run.
    private var isClosed = false

    /// Who the document is to its engine's background work.
    private var backgroundWorkMember: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    /// The background indexing of the engine the document is on, shared with
    /// every document on the engine (`RuntimeEngineBackgroundWork`): they all
    /// show its batches and its history, and Cancel or Clear History in any of
    /// them speaks for all of them.
    ///
    /// Brought into being on first use — `makeWindowControllers` touches it —
    /// and kept by the engine for as long as a document is on it, even when
    /// the feature is disabled at open time, so it can react to settings
    /// off→on toggles. Deferring the creation is an init-deferral mechanism,
    /// not a gating-by-enablement. The document reads the engine's coordinator
    /// afresh after every move to another engine; `$runtimeEngine` says when.
    public var backgroundIndexingCoordinator: RuntimeBackgroundIndexingCoordinator {
        let backgroundWork = joinedBackgroundWork()
        if !isClosed {
            needsBackgroundIndexing = true
        }
        return backgroundWork.indexingCoordinator
    }

    /// Per-Document interface cache. Content navigation (push, tab switch,
    /// back/forward) rebinds `ContentTextViewModel` and used to re-fetch
    /// the interface over XPC on every rebind; routing single-object
    /// fetches through this cache makes revisits render from memory. See
    /// `RuntimeInterfaceCache` for the invalidation contract (engine swaps
    /// and `dataChangePublisher` events flush it).
    public private(set) lazy var interfaceCache = RuntimeInterfaceCache(documentState: self)

    /// The Find navigator's query and results, shared by the page in each
    /// sidebar level. See `FindSession`.
    public var findSession: FindSession {
        if let findSessionStorage {
            return findSessionStorage
        }
        let findSession = FindSession(documentState: self)
        findSessionStorage = findSession
        return findSession
    }

    private var findSessionStorage: FindSession?

    /// Keeps the engine's interface corpus in step with what the engine
    /// indexes, shared with every document on the engine like
    /// `backgroundIndexingCoordinator`, and touched on the same Document
    /// lifecycle hook. The document's Find session follows it, and it hears
    /// which image the document's sidebar shows.
    public var findCorpusCoordinator: FindCorpusCoordinator {
        let backgroundWork = joinedBackgroundWork()
        if !needsInterfaceCorpus, !isClosed {
            needsInterfaceCorpus = true
            followInterfaceCorpus(of: backgroundWork)
        }
        return backgroundWork.corpusCoordinator
    }

    /// Keeps the engine's prepared cross references in step with what the
    /// engine indexes, shared with every document on the engine like
    /// `backgroundIndexingCoordinator`, and touched on the same Document
    /// lifecycle hook.
    public var crossReferencePreparationCoordinator: CrossReferencePreparationCoordinator {
        let backgroundWork = joinedBackgroundWork()
        if !isClosed {
            needsCrossReferencePreparation = true
        }
        return backgroundWork.crossReferencePreparationCoordinator
    }

    /// The work of the engine the document is on, joined if the document does
    /// not hold it yet. A document that closed without ever holding it gets
    /// work closed from the start: it asks the engine for nothing.
    private func joinedBackgroundWork() -> RuntimeEngineBackgroundWork {
        if let backgroundWork {
            return backgroundWork
        }
        let joinedBackgroundWork = isClosed
            ? RuntimeEngineBackgroundWork.closed(on: runtimeEngine)
            : backgroundWorkRegistry.join(runtimeEngine, as: backgroundWorkMember)
        backgroundWork = joinedBackgroundWork
        return joinedBackgroundWork
    }

    /// Hooks the document's Find session, and its sidebar's image, to
    /// `backgroundWork`'s corpus coordinator.
    private func followInterfaceCorpus(of backgroundWork: RuntimeEngineBackgroundWork) {
        let corpusCoordinator = backgroundWork.corpusCoordinator
        findSession.follow(corpusCoordinator)
        corpusCoordinator.setOnScreenImagePath(currentImageNode?.path, ofDocument: backgroundWorkMember)
    }

    /// Lets go of the background work the document holds: the last document
    /// on its engine letting go closes it, cancelling what it still runs.
    private func leaveBackgroundWork(_ backgroundWork: RuntimeEngineBackgroundWork) {
        if needsInterfaceCorpus {
            backgroundWork.corpusCoordinator.setOnScreenImagePath(nil, ofDocument: backgroundWorkMember)
        }
        backgroundWorkRegistry.leave(backgroundWork, as: backgroundWorkMember)
    }

    /// Carries the document's hold on background work to `engine`, the engine
    /// `.switchEngine` is putting in place: the old engine's work is left —
    /// and closed when the document was the last one on it — and the new
    /// engine's is joined, with what the document needed of the old one. A
    /// document that never needed any joins the new engine's on first use.
    fileprivate func moveBackgroundWork(to engine: RuntimeEngine) {
        guard let previousBackgroundWork = backgroundWork, !isClosed else { return }
        leaveBackgroundWork(previousBackgroundWork)
        let joinedBackgroundWork = backgroundWorkRegistry.join(engine, as: backgroundWorkMember)
        backgroundWork = joinedBackgroundWork
        if needsInterfaceCorpus {
            followInterfaceCorpus(of: joinedBackgroundWork)
        }
        if needsCrossReferencePreparation {
            _ = joinedBackgroundWork.crossReferencePreparationCoordinator
        }
        if needsBackgroundIndexing {
            joinedBackgroundWork.indexingCoordinator.documentDidOpen()
        }
    }

    /// Tells the engine's corpus coordinator which image the sidebar lists
    /// now; the routes that change `currentImageNode` call it.
    fileprivate func currentImageNodeDidChange() {
        guard needsInterfaceCorpus, !isClosed, let backgroundWork else { return }
        backgroundWork.corpusCoordinator.setOnScreenImagePath(currentImageNode?.path, ofDocument: backgroundWorkMember)
    }

    /// Whether `findSession` has been brought into being. Test seam.
    var hasCreatedFindSession: Bool {
        findSessionStorage != nil
    }

    /// Keeps the app out of App Nap while `reportActivity` says this document has work in
    /// progress. Like the coordinators it watches, touched on the first Document lifecycle hook
    /// so it exists for the document's whole life.
    public var backgroundWorkProcessActivity: BackgroundWorkProcessActivity {
        if let backgroundWorkProcessActivityStorage {
            return backgroundWorkProcessActivityStorage
        }
        let backgroundWorkProcessActivity = BackgroundWorkProcessActivity(isWorkInProgress: reportActivity, scheduler: processActivityScheduler)
        backgroundWorkProcessActivityStorage = backgroundWorkProcessActivity
        return backgroundWorkProcessActivity
    }

    private var backgroundWorkProcessActivityStorage: BackgroundWorkProcessActivity?

    /// What `backgroundWorkProcessActivity` begins and ends its activity with, read when it is
    /// brought into being. Test seam.
    var processActivityScheduler: any ProcessActivityScheduling = ProcessInfo.processInfo

    /// Whether the document has needed `findCorpusCoordinator`. Test seam.
    var hasCreatedFindCorpusCoordinator: Bool {
        needsInterfaceCorpus
    }

    /// Whether `backgroundWorkProcessActivity` has been brought into being. Test seam.
    var hasCreatedBackgroundWorkProcessActivity: Bool {
        backgroundWorkProcessActivityStorage != nil
    }

    /// The document is closing; `Document.close()` calls this and nothing
    /// else. The document lets go of its engine's background work — the last
    /// document on the engine letting go stops it, cancelling the indexing
    /// batches and corpus builds still under way and dropping its Report;
    /// with other documents on the engine, it runs on for them — and each
    /// member of its own that exists lets go of its work — the search under
    /// way, the activity held for them — and stops reacting to anything. A
    /// member never brought into being stays that way: creating it now would
    /// only start the observation and the requests closing is meant to stop.
    ///
    /// Needed because this object can outlive its window, and with it every
    /// member it holds, so their `deinit` is no place to let go of work.
    public func documentWillClose() {
        guard !isClosed else { return }
        isClosed = true
        if let backgroundWork {
            leaveBackgroundWork(backgroundWork)
        }
        findSessionStorage?.documentWillClose()
        backgroundWorkProcessActivityStorage?.documentWillClose()
    }

    /// Whether the Report navigator has work in progress: an indexing batch, a corpus queued or
    /// being printed, or cross references queued or being prepared, on the engine the document is
    /// on. Worked out once here, so both sidebar levels mark their Report navigator tab from the
    /// same answer.
    public var reportActivity: Driver<Bool> {
        $runtimeEngine.asDriver()
            .flatMapLatest { [weak self] _ -> Driver<Bool> in
                guard let self else { return .just(false) }
                return MainActor.assumeIsolated {
                    Driver.combineLatest(
                        self.backgroundIndexingCoordinator.hasActiveBatchObservable.asDriver(onErrorJustReturn: false),
                        self.findCorpusCoordinator.hasActiveBuild,
                        self.crossReferencePreparationCoordinator.hasActivePreparation
                    ) { hasActiveBatch, hasActiveBuild, hasActivePreparation in
                        hasActiveBatch || hasActiveBuild || hasActivePreparation
                    }
                }
            }
            .distinctUntilChanged()
    }
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
            if documentState.runtimeEngine === engine, documentState.hasNothingOpen { return }
            if documentState.runtimeEngine !== engine {
                documentState.observeReadiness(of: engine)
                // Before the engine is assigned, so whatever follows
                // `$runtimeEngine` finds the new engine's coordinators.
                documentState.moveBackgroundWork(to: engine)
            }
            documentState.runtimeEngine = engine
            documentState.currentImageNode = nil
            documentState.currentImageNodeDidChange()
            resetHistory()
            // Engine switch resets the whole document: collapse back to a
            // single empty tab.
            documentState.tabs = [DocumentTab()]
            documentState.activeTabIndex = 0
        case .switchImage(let node):
            if documentState.currentImageNode == node, documentState.selectionStack.isEmpty { return }
            documentState.currentImageNode = node
            documentState.currentImageNodeDidChange()
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
        case .pushHighlighting(let object, _):
            // The highlight rides on the route itself, to the content pane.
            pushOntoTimeline(object)
        case .openInNewTabHighlighting(let object, _):
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
        // Announced once the document stands on the engine, like the route.
        if case .switchEngine(let engine) = route {
            documentState.runtimeEngineDidResetRelay.accept(engine)
        }
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
    /// branch, appends the entry unless the same type already sits at the top
    /// (consecutive duplicates only move the cursor), and shows it.
    ///
    /// A duplicate still replaces the top entry when it arrives in another
    /// form — the sidebar's object after a link payload, or the reverse — so
    /// the entry holds what is on screen. Keeping the first form instead would
    /// have back / forward restore a form the user has already navigated away
    /// from, with whatever `displayName` and `properties` it carried.
    private func pushOntoTimeline(_ object: RuntimeObject) {
        truncateForwardBranch()
        let selectionStack = documentState.selectionStack
        if let topEntry = selectionStack.last, topEntry == object {
            if !topEntry.hasSameContent(as: object) {
                documentState.selectionStack[selectionStack.count - 1] = object
            }
        } else {
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
    /// tab already holds that object in that state. Compared by content, not
    /// identity: the same type arriving in another form carries another
    /// `displayName` for the title and other `properties` for the panes a tab
    /// switch hands it back to.
    private func syncActiveTabObject() {
        let index = documentState.activeTabIndex
        guard index >= 0, index < documentState.tabs.count else { return }
        let currentObject = documentState.selectedRuntimeObject
        let isInSync = switch (documentState.tabs[index].object, currentObject) {
        case (nil, nil): true
        case (let tabObject?, let selectedObject?): tabObject.hasSameContent(as: selectedObject)
        default: false
        }
        guard !isInSync else { return }
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
