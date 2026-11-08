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
        self.runtimeEngineSession = RuntimeEngineSession(engine: runtimeEngine)
        observeReadiness(of: runtimeEngine)
        followSidebarImage()
        followOwnersReadiness()
    }

    /// The engine backing this Document and the document's hold on the
    /// engine's background work, as one value: whatever follows it finds the
    /// engine and the work that goes with it together. Read-only externally.
    ///
    /// A new session is put in place when the document starts its background
    /// work (`startBackgroundWork()`) and when the `.switchEngine` route moves
    /// it to another engine; the same engine starting over with something
    /// open puts the same session in place again, and closing puts nothing in
    /// place. `MainCoordinator` is responsible for issuing that route from its
    /// `.main` handler — the trigger also atomically clears `currentImageNode`
    /// and starts `editorArea` over, so consumers never observe a
    /// half-switched state.
    @RxObserved
    public fileprivate(set) var runtimeEngineSession: RuntimeEngineSession

    /// The runtime engine backing this Document: `runtimeEngineSession`'s.
    /// Follow `$runtimeEngineSession` to hear it change.
    public var runtimeEngine: RuntimeEngine {
        runtimeEngineSession.engine
    }

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
    /// `$runtimeEngineSession` does not cover the second case: nothing is put
    /// in place when nothing is open.
    public var runtimeEngineDidReset: Signal<RuntimeEngine> {
        runtimeEngineDidResetRelay.asSignal()
    }

    fileprivate let runtimeEngineDidResetRelay = PublishRelay<RuntimeEngine>()

    /// Fires with the document's engine when it came back — the process
    /// behind it is new — while the document had something open: the window
    /// is to start the document over on it, the way choosing the engine again
    /// does. On macOS that is `MainRoute.main`, which stops listening to the
    /// document's routes, issues `.switchEngine` onto the engine and builds
    /// new panes. The document does not issue the route itself: reaching the
    /// panes about to be replaced, it is the broken contract
    /// `MainCoordinator.fanOut` asserts on. With nothing open there is nothing
    /// to start over from, and only `runtimeEngineDidReset` fires.
    public var startOverRequested: Signal<RuntimeEngine> {
        startOverRequestedRelay.asSignal()
    }

    private let startOverRequestedRelay = PublishRelay<RuntimeEngine>()

    /// The sidebar at the image list and no tab of any editor pane having
    /// shown anything: an engine coming back has nothing to walk the document
    /// back from.
    fileprivate var hasNothingOpen: Bool {
        currentImageNode == nil && editorArea.hasShownNothing
    }

    /// Watches the engine for coming back — it stops being ready and then
    /// becomes ready again — after which the document walks back to the
    /// image list.
    ///
    /// That edge is the local XPC service having been relaunched —
    /// after a crash, or after the system reclaimed it while it sat idle:
    /// the engine object survives, but the process behind it is new and holds
    /// none of the images this document was browsing, so every request from
    /// where the user stands would fail. The `.switchEngine` route onto the
    /// same engine is the existing "start over on this engine" reset, and the
    /// window issues it when asked (`startOverRequested`). With nothing open
    /// it would be a no-op, so the edge then only announces the reset
    /// (`runtimeEngineDidReset`) — the engine's very first connection
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
        observeSharedCacheOwners(of: engine)
    }

    private func handleReadinessChange(_ isReady: Bool, of engine: RuntimeEngine) {
        guard engine === runtimeEngine else { return }
        let becameReadyAgain = isReady && !engineWasReady
        engineWasReady = isReady
        guard becameReadyAgain else { return }
        startOverOrAnnounceReset(on: engine)
    }

    /// The document starts over on `engine`: the window walks it back when it
    /// has something open, and otherwise only the reset is announced.
    private func startOverOrAnnounceReset(on engine: RuntimeEngine) {
        if hasNothingOpen {
            runtimeEngineDidResetRelay.accept(engine)
        } else {
            startOverRequestedRelay.accept(engine)
        }
    }

    // MARK: - Shared cache owners

    /// Subscription to the current engine's shared cache owners; see
    /// ``observeSharedCacheOwners(of:)``.
    private var sharedCacheOwnersSubscription: AnyCancellable?

    /// Subscriptions to the readiness of the engines the current session
    /// borrows from, by engine.
    private var ownerReadinessSubscriptions: [ObjectIdentifier: AnyCancellable] = [:]

    /// Whether each engine the current session borrows from was ready at its
    /// last readiness event.
    private var ownerWasReady: [ObjectIdentifier: Bool] = [:]

    /// Watches the engine manager give the engine other owners: My Mac and
    /// Mac Catalyst coming up or going, the engine attached, sharing turned
    /// off in Settings › Developer. A new session is put in place, holding the
    /// new owners' work in place of the old ones', and a document that was
    /// borrowing starts over as when its engine comes back: what it showed of
    /// a borrowed image came from an owner it no longer asks. A document that
    /// borrowed nothing before showed nothing an owner gave it, and only
    /// moves to the new session.
    private func observeSharedCacheOwners(of engine: RuntimeEngine) {
        sharedCacheOwnersSubscription = engine.sharedCacheOwnersPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak engine] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine else { return }
                    self.sharedCacheOwnersDidChange(of: engine)
                }
            }
    }

    private func sharedCacheOwnersDidChange(of engine: RuntimeEngine) {
        guard engine === runtimeEngine, !isClosed else { return }
        let previousSession = runtimeEngineSession
        guard previousSession.sharedCacheOwners != engine.sharedCacheOwners else { return }
        let wasBorrowing = previousSession.borrowsSharedCacheImages
        runtimeEngineSession = previousSession.successor(on: engine)
        previousSession.leave()
        if wasBorrowing {
            startOverOrAnnounceReset(on: engine)
        }
    }

    /// Follows the readiness of the engines each session borrows from. An
    /// owner coming back — the local or the Mac Catalyst service relaunched —
    /// holds none of the images it kept for the document, so the document
    /// starts over as when its own engine comes back.
    private func followOwnersReadiness() {
        $runtimeEngineSession.asObservable()
            .subscribeOnNext { [weak self] session in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.observeReadiness(ofOwners: session.ownerEngines)
                }
            }
            .disposed(by: disposeBag)
    }

    private func observeReadiness(ofOwners ownerEngines: [RuntimeEngine]) {
        let ownerIdentifiers = Set(ownerEngines.map(ObjectIdentifier.init))
        let departedOwnerIdentifiers = ownerReadinessSubscriptions.keys.filter { !ownerIdentifiers.contains($0) }
        for ownerIdentifier in departedOwnerIdentifiers {
            ownerReadinessSubscriptions[ownerIdentifier] = nil
            ownerWasReady[ownerIdentifier] = nil
        }
        for ownerEngine in ownerEngines {
            let ownerIdentifier = ObjectIdentifier(ownerEngine)
            guard ownerReadinessSubscriptions[ownerIdentifier] == nil else { continue }
            ownerWasReady[ownerIdentifier] = ownerEngine.state.isReady
            ownerReadinessSubscriptions[ownerIdentifier] = ownerEngine.statePublisher
                .map(\.isReady)
                .sink { [weak self, weak ownerEngine] isReady in
                    Task { @MainActor [weak self, weak ownerEngine] in
                        guard let self, let ownerEngine else { return }
                        self.handleReadinessChange(isReady, ofOwner: ownerEngine)
                    }
                }
        }
    }

    private func handleReadinessChange(_ isReady: Bool, ofOwner ownerEngine: RuntimeEngine) {
        let ownerIdentifier = ObjectIdentifier(ownerEngine)
        guard ownerReadinessSubscriptions[ownerIdentifier] != nil, !isClosed else { return }
        let becameReadyAgain = isReady && ownerWasReady[ownerIdentifier] == false
        ownerWasReady[ownerIdentifier] = isReady
        guard becameReadyAgain else { return }
        startOverOrAnnounceReset(on: runtimeEngine)
    }

    /// The image the sidebar lists. `nil` when the sidebar is at the
    /// image-picker root. Changing it leaves the editor area alone: an object
    /// of another image stays open where it is. Read-only externally: mutated
    /// only via the `.switchImage` route.
    @RxObserved
    public fileprivate(set) var currentImageNode: RuntimeImageNode?

    /// The editor area: its panes, each pane's tabs, each tab's history, how
    /// the panes are arranged and which one has the focus (proposal
    /// `editor-panes`). One value, so that no reader sees a layout and
    /// a set of panes that disagree.
    ///
    /// Read-only externally: every mutation goes through `selectionRouter`,
    /// which dispatches a typed `SelectionRoute` and emits to `routeSignal`
    /// after the state update has been applied. Its equality compares objects
    /// by identity, so do not `distinctUntilChanged()` it raw where a title
    /// or another field of an object is shown: compare what is shown.
    @RxObserved
    public fileprivate(set) var editorArea: EditorArea = EditorArea()

    /// What the focused editor pane's active tab shows, or `nil` for an empty
    /// tab. Every route keeps it the same as
    /// `editorArea.focusedPane.activeTab.object`, in the same form; it stays a
    /// property of its own because the sidebar, the Inspector, the toolbar,
    /// Find and MCP follow the object on screen, whichever pane shows it.
    /// Read-only externally: mutated only via `selectionRouter`.
    @RxObserved
    public fileprivate(set) var selectedRuntimeObject: RuntimeObject?

    /// The member whose declaration the focused pane's insertion point is on,
    /// or `nil` when the point is on no member's line. The Inspector's
    /// References tab follows it, and Find Call Hierarchy in the main menu acts
    /// on it, as Xcode's acts on the symbol at the insertion point. Each
    /// content pane reports its own (`updateCursorMember(_:inEditorPane:)`),
    /// reading which line declares which member
    /// (`RuntimeObjectInterface.declaredMembersByLineNumber()`); this is the
    /// focused pane's.
    @RxObserved
    public private(set) var cursorMember: RuntimeMemberReference?

    /// The member each pane's insertion point is on, kept out of `editorArea`:
    /// it moves with every keystroke, and every pane follows the area.
    private var cursorMembersByEditorPane: [EditorPane.ID: RuntimeMemberReference] = [:]

    /// Records where `paneID`'s insertion point is; the focused pane's becomes
    /// `cursorMember`.
    public func updateCursorMember(_ member: RuntimeMemberReference?, inEditorPane paneID: EditorPane.ID) {
        cursorMembersByEditorPane[paneID] = member
        syncCursorMember()
    }

    private func syncCursorMember() {
        let member = cursorMembersByEditorPane[editorArea.focusedPaneID]
        guard member != cursorMember else { return }
        cursorMember = member
    }

    /// Brings `selectedRuntimeObject` and `cursorMember` in line with
    /// `editorArea`, assigning only what changed, and forgets the insertion
    /// points of panes that have closed. The router calls it after every
    /// route.
    fileprivate func syncWithEditorArea() {
        let focusedObject = editorArea.focusedPane.activeTab.object
        let isInSync = switch (selectedRuntimeObject, focusedObject) {
        case (nil, nil): true
        case (let selectedObject?, let focusedObject?): selectedObject.hasSameContent(as: focusedObject)
        default: false
        }
        if !isInSync {
            selectedRuntimeObject = focusedObject
        }
        cursorMembersByEditorPane = cursorMembersByEditorPane.filter { editorArea[$0.key] != nil }
        syncCursorMember()
    }

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
    /// (`documentState.selectionRouter.trigger(.open(object, in: .focusedTab))`). The router
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

    /// `documentWillClose()` has run.
    private var isClosed = false

    /// Who the document is to its engine's background work.
    private var backgroundWorkMember: ObjectIdentifier {
        ObjectIdentifier(self)
    }

    private let disposeBag = DisposeBag()

    /// Joins the background work of the engine the document is on — the
    /// engine's background indexing, its interface corpus and its prepared
    /// cross references, shared with every document on the engine
    /// (`RuntimeEngineBackgroundWork`), which keeps the app out of App Nap while
    /// any of it is in progress. The first document on an engine starts the
    /// engine's indexing; the document's Find session follows the engine's
    /// corpus coordinator, which hears which image the document's sidebar
    /// shows.
    ///
    /// The only way in. It puts a new session in place, holding the work, so
    /// whatever followed `$runtimeEngineSession` before — a page bound early,
    /// the Find session — finds the work from then on.
    /// `Document.makeWindowControllers` calls this first all the same. Calling
    /// it again, or once the document has closed, does nothing.
    public func startBackgroundWork() {
        guard runtimeEngineSession.backgroundWork == nil, !isClosed else { return }
        runtimeEngineSession = RuntimeEngineSession(joining: runtimeEngine, as: backgroundWorkMember, through: backgroundWorkRegistry)
    }

    /// Puts a session on `engine` in place of the current one — holding
    /// `engine`'s background work if the document started its own — and then
    /// lets the current one go: whatever follows the session never finds the
    /// new engine without its work, and the old engine's work closes once its
    /// last document has left. `.switchEngine` calls this for another engine.
    fileprivate func moveSession(to engine: RuntimeEngine) {
        let previousSession = runtimeEngineSession
        runtimeEngineSession = isClosed ? RuntimeEngineSession(engine: engine) : previousSession.successor(on: engine)
        previousSession.leave()
    }

    /// The same engine starting over with something open: the session stays,
    /// put in place again so whatever follows it starts over too — the
    /// interface cache empties. `.switchEngine` calls this for the engine the
    /// document is on.
    fileprivate func putSessionInPlaceAgain() {
        let currentSession = runtimeEngineSession
        runtimeEngineSession = currentSession
    }

    /// Tells the corpus coordinators of the work the document holds which image
    /// its sidebar lists, whenever the session or the image changes: the
    /// coordinator of the work that keeps the image's data hears it, the others
    /// hear none — a shared cache image the engine borrows is its owner's to
    /// favour. With no work held, nothing. A session the document leaves
    /// withdraws the image itself (`RuntimeEngineSession.leave()`), and a closed
    /// document tells nothing.
    private func followSidebarImage() {
        Observable.combineLatest($runtimeEngineSession.asObservable(), $currentImageNode.asObservable())
            .subscribeOnNext { [weak self] session, currentImageNode in
                MainActor.assumeIsolated {
                    guard let self, !self.isClosed else { return }
                    let imagePath = currentImageNode?.path
                    for backgroundWork in session.backgroundWorks {
                        let onScreenImagePath = imagePath.flatMap { session.keepsData(ofImageAt: $0, in: backgroundWork) ? $0 : nil }
                        backgroundWork.corpusCoordinator.setOnScreenImagePath(onScreenImagePath, ofDocument: self.backgroundWorkMember)
                    }
                }
            }
            .disposed(by: disposeBag)
    }

    /// Per-Document interface cache. Content navigation (push, tab switch,
    /// back/forward) rebinds `ContentTextViewModel` and used to re-fetch
    /// the interface over XPC on every rebind; routing single-object
    /// fetches through this cache makes revisits render from memory. See
    /// `RuntimeInterfaceCache` for the invalidation contract (every session
    /// put in place and every `dataChangePublisher` event flush it).
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

    /// Whether `findSession` has been brought into being. Test seam.
    var hasCreatedFindSession: Bool {
        findSessionStorage != nil
    }

    /// The document is closing; `Document.close()` calls this and nothing
    /// else. The document lets go of its engine's background work — the last
    /// document on the engine letting go stops it, cancelling the indexing
    /// batches and corpus builds still under way, dropping its Report and
    /// letting go of the activity that kept the app out of App Nap; with other
    /// documents on the engine, it runs on for them — and each member of its
    /// own that exists lets go of its work — the search under way — and stops
    /// reacting to anything. A member never brought into being stays that way:
    /// creating it now would only start the observation and the requests
    /// closing is meant to stop. The session stays in place, so a late reader
    /// finds the work the document left, closed or running for the documents
    /// still on the engine.
    ///
    /// Needed because this object can outlive its window, and with it every
    /// member it holds, so their `deinit` is no place to let go of work.
    public func documentWillClose() {
        guard !isClosed else { return }
        isClosed = true
        runtimeEngineSession.leave()
        findSessionStorage?.documentWillClose()
    }

    /// Whether the Report navigator has work in progress: an indexing batch, a corpus queued or
    /// being printed, or cross references queued or being prepared, on the engine the document is
    /// on. The engine's work works it out once for every document on it
    /// (`RuntimeEngineBackgroundWork.isWorkInProgress`), so both sidebar levels of every window on
    /// the engine mark their Report navigator tab from the same answer. False while the document
    /// holds none of its engine's work.
    public var reportActivity: Driver<Bool> {
        $runtimeEngineSession.asDriver()
            .flatMapLatest { session -> Driver<Bool> in
                MainActor.assumeIsolated {
                    session.backgroundWork?.isWorkInProgress ?? .just(false)
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
        // Every case returns before emitting when the route changes nothing, so a
        // subscriber never rebuilds a pane for a no-op.
        switch route {
        case .switchEngine(let engine):
            if documentState.runtimeEngine === engine, documentState.hasNothingOpen { return }
            if documentState.runtimeEngine !== engine {
                documentState.observeReadiness(of: engine)
                documentState.moveSession(to: engine)
            } else {
                documentState.putSessionInPlaceAgain()
            }
            documentState.currentImageNode = nil
            // Everything open belonged to the engine left behind: start over
            // with one empty pane.
            documentState.editorArea = EditorArea()
        case .switchImage(let node):
            // Only the sidebar moves; the editor area keeps every object open,
            // whichever image it belongs to.
            guard documentState.currentImageNode != node else { return }
            documentState.currentImageNode = node
        case .open(let object, let destination, _):
            // The highlight rides on the route itself, to the content pane.
            documentState.editorArea.open(object, in: destination)
        case .selectAtRoot(let object):
            documentState.editorArea.resetFocusedTab(to: object)
        case .backward:
            guard documentState.editorArea.goBackward() else { return }
        case .forward:
            guard documentState.editorArea.goForward() else { return }
        case .jump(let toIndex):
            guard documentState.editorArea.goToHistoryEntry(at: toIndex) else { return }
        case .newTab:
            documentState.editorArea.addEmptyTab()
        case .switchTab(let tabID):
            guard documentState.editorArea.selectTab(tabID) else { return }
        case .closeTab(let tabID):
            // The only tab of the only pane is never closed here — the menu
            // layer turns ⌘W into "close window" in that state.
            guard documentState.editorArea.closeTab(tabID) else { return }
        case .moveTab(let tabID, let toIndex):
            guard documentState.editorArea.moveTab(tabID, to: toIndex) else { return }
        case .newEditorPane(let placement):
            documentState.editorArea.addPane(placed: placement)
        case .closeEditorPane(let paneID):
            guard documentState.editorArea.closePane(paneID) else { return }
        case .closeOtherEditorPanes:
            guard documentState.editorArea.closeOtherPanes() else { return }
        case .focusEditorPane(let paneID):
            guard documentState.editorArea.focus(paneID) else { return }
        case .changeEditorOrientation:
            documentState.editorArea.changeOrientation()
        }
        documentState.syncWithEditorArea()
        routeRelay.accept(route)
        // Announced once the document stands on the engine, like the route.
        if case .switchEngine(let engine) = route {
            documentState.runtimeEngineDidResetRelay.accept(engine)
        }
        completion?(EmptyRouteTransitionContext.shared)
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
