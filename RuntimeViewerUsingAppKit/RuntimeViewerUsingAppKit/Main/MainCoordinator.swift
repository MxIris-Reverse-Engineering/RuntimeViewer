import AppKit
import RuntimeViewerCore
import RuntimeViewerInjection
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerMCPBridge
import LateResponders

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>, LateResponderRegistering {

    let documentState: DocumentState

    private lazy var sidebarCoordinator = SidebarCoordinator(documentState: documentState)

    private lazy var contentCoordinator = ContentCoordinator(documentState: documentState)

    private lazy var inspectorCoordinator = InspectorCoordinator(documentState: documentState)

    private lazy var viewModel = MainViewModel(documentState: documentState, router: self)

    private(set) lazy var lateResponderRegistry = LateResponderRegistry()

    /// Subscription to `documentState.routeSignal`. Renewed on every
    /// engine switch (`.main` case) because the fan-out captures the
    /// currently-installed sub-coordinators by reference; tearing down the
    /// old subscription before the silent state reset prevents stale
    /// `.placeholder` / `.back` transitions from being queued on
    /// soon-to-be-discarded coordinators.
    private var routeDisposeBag = DisposeBag()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(windowController: .init(documentState: documentState), initialRoute: .main(documentState.runtimeEngine))
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .main(let runtimeEngine):
            // Drop the previous subscription FIRST so the upcoming
            // `.switchEngine` reset emits with no listener, leaving the
            // dying sub-coordinators untouched.
            routeDisposeBag = DisposeBag()
            documentState.selectionRouter.trigger(.switchEngine(runtimeEngine))

            sidebarCoordinator.removeFromParent()
            contentCoordinator.removeFromParent()
            inspectorCoordinator.removeFromParent()
            sidebarCoordinator = SidebarCoordinator(documentState: documentState)
            contentCoordinator = ContentCoordinator(documentState: documentState)
            inspectorCoordinator = InspectorCoordinator(documentState: documentState)
            inspectorCoordinator.delegate = self
            rootWindowController.setupBindings(for: viewModel)

            // Subscribe with the fresh sub-coordinators in place.
            documentState.routeSignal
                .emit(with: self) { $0.fanOut($1) }
                .disposed(by: routeDisposeBag)
            documentState.findSession.showResultsRequested
                .emit(with: self) { coordinator, _ in coordinator.trigger(.showFindResults) }
                .disposed(by: routeDisposeBag)
            // The engine came back while the document had something open: start over on it
            // the way choosing it again does, so the reset reaches no pane about to be replaced.
            documentState.startOverRequested
                .emit(with: self) { coordinator, runtimeEngine in coordinator.trigger(.main(runtimeEngine)) }
                .disposed(by: routeDisposeBag)

            return .multiple(
                .show(rootWindowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root),
                .route(on: contentCoordinator, to: .placeholder),
                .route(on: inspectorCoordinator, to: .placeholder),
            )
        case .generationOptions:
            guard let anchorView = popoverAnchorView(of: rootWindowController.toolbarController.generationOptionsItem) else { return .none() }
            let viewController = GenerationOptionsViewController()
            let viewModel = GenerationOptionsViewModel(documentState: documentState, router: self)
            viewController.loadViewIfNeeded()
            viewController.setupBindings(for: viewModel)
            return .popover(viewController, relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY, behavior: .transient)
        case .mcpStatus:
            guard let anchorView = popoverAnchorView(of: rootWindowController.toolbarController.mcpStatusItem) else { return .none() }
            let viewController = MCPStatusPopoverViewController()
            let viewModel = MCPStatusPopoverViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .popover(viewController, relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .maxY, behavior: .transient)
        case .attachToProcess:
            // Which machine's processes the sheet offers follows the selected engine. The
            // host case is the one that already worked and keeps enumerating locally; a
            // device lists its own processes, and must not be shown this Mac's.
            let runtimeEngine = documentState.runtimeEngine
            let target: AttachToProcessViewController.Target = runtimeEngine.injectionTargetsRunOnThisMachine
                ? .hostProcesses
                : .remoteProcesses(RemoteProcessItemSource(runtimeEngine: runtimeEngine))
            let viewController = AttachToProcessViewController(target: target)
            // The same engine reaches both halves, so the list the user sees and the
            // machine the injection goes to cannot drift apart.
            let viewModel = AttachToProcessViewModel(
                attachmentEngine: runtimeEngine,
                documentState: documentState,
                router: self
            )
            viewController.setupBindings(for: viewModel)
            viewController.preferredContentSize = .init(width: 800, height: 600)
            return .presentOnRoot(viewController, mode: .asSheet)
        case .dismiss:
            return .dismiss()
        case .exportInterfaces:
            guard let exportingCoordinator = ExportingCoordinator(documentState: documentState) else { return .none() }
            addChild(exportingCoordinator)
            return .beginSheet(exportingCoordinator)
        case .exportMultipleImages:
            let batchExportingCoordinator = BatchExportingCoordinator(documentState: documentState)
            addChild(batchExportingCoordinator)
            return .beginSheet(batchExportingCoordinator)
        case .beginSpecializationSheet(let object):
            let specializationCoordinator = SpecializationCoordinator(
                documentState: documentState,
                runtimeObject: object
            )
            specializationCoordinator.delegate = self
            addChild(specializationCoordinator)
            return .beginSheet(specializationCoordinator)
        case .revealInSidebarNavigator:
            // Split view item 0 is the sidebar. `.multiple` runs the reveal
            // once the expansion has finished, and `.trigger` prepares the
            // sidebar's transition only then, against the sidebar on screen.
            return .multiple(
                .expand(itemAt: 0),
                .trigger(.revealSelectedRuntimeObject, on: sidebarCoordinator)
            )
        case .find:
            return .multiple(
                .expand(itemAt: 0),
                .trigger(.showFind, on: sidebarCoordinator)
            )
        case .showFindResults:
            return .multiple(
                .expand(itemAt: 0),
                .trigger(.showFindResults, on: sidebarCoordinator)
            )
        case .reports:
            return .multiple(
                .expand(itemAt: 0),
                .trigger(.showReports, on: sidebarCoordinator)
            )
        }
    }

    /// The button a popover about `toolbarItem` anchors at, looked up here so
    /// that neither the route nor the view model carries a view. `nil` while
    /// the item sits in the toolbar's overflow menu, where its button is in no
    /// window and cannot anchor anything.
    private func popoverAnchorView(of toolbarItem: MainToolbarController.IconButtonToolbarItem) -> NSView? {
        let button = toolbarItem.button
        return button.window != nil ? button : nil
    }

    override func completeTransition(for route: MainRoute) {
        switch route {
        case .main:
            rootWindowController.splitViewController.setupSplitViewItems()
        default:
            break
        }
    }

    override var nextResponder: NSResponder? {
        set {
            lateResponderRegistry.lastResponder.nextResponder = newValue
        }
        get {
            lateResponderRegistry.initialResponder
        }
    }

    // MARK: - Route fan-out
    //
    // Receives each `SelectionRoute` after `DocumentState` has applied its
    // state mutation, and translates it into typed routes on the three
    // sub-coordinators. This is the only place that knows how a route
    // affects each pane.

    private func fanOut(_ route: SelectionRoute) {
        switch route {
        case .switchEngine:
            // `.switchEngine` is exclusively triggered from the `.main`
            // route handler above, which tears down the subscription
            // before triggering. Reaching this branch means a contract
            // violation — log once, take no action (the handler is the
            // only path that can correctly rebuild the sub-coordinators).
            // An engine coming back asks for `.main` through
            // `DocumentState.startOverRequested` rather than issuing it.
            assertionFailure(".switchEngine fired with an active route subscriber; engine switches must go through MainRoute.main")
        case .switchImage(let node):
            // Only the sidebar moves: what the editor area shows stays, and so
            // does the Inspector, which follows it.
            if let node {
                sidebarCoordinator.contextTrigger(.clickedNode(node))
            } else {
                sidebarCoordinator.contextTrigger(.back)
            }
        case .open(let object, let destination, let highlightRequest):
            // The highlight travels with the content route, so it lives exactly as long as the
            // content ViewModel built for this navigation. A new tab starts its pane's scene over;
            // the focused tab and the next pane move on from what they showed.
            switch (destination, highlightRequest) {
            case (.newTab, nil):
                contentCoordinator.contextTrigger(.root(object))
            case (.newTab, let highlightRequest?):
                contentCoordinator.contextTrigger(.rootHighlighting(object, highlightRequest))
            case (.focusedTab, nil), (.nextEditorPane, nil):
                contentCoordinator.contextTrigger(.next(object))
            case (.focusedTab, let highlightRequest?), (.nextEditorPane, let highlightRequest?):
                contentCoordinator.contextTrigger(.nextHighlighting(object, highlightRequest))
            }
            inspectorCoordinator.contextTrigger(.next(.object(object)))
            // Sidebar visual sync is handled inside
            // `SidebarRuntimeObjectListViewModel` by observing
            // `documentState.$selectedRuntimeObject` directly — no
            // coordinator routing is needed for a pure UI
            // scroll-and-highlight.
        case .selectAtRoot(let object):
            contentCoordinator.contextTrigger(.root(object))
            inspectorCoordinator.contextTrigger(.root(.object(object)))
        case .backward, .forward, .jump, .newTab, .switchTab, .closeTab, .moveTab,
             .newEditorPane, .closeEditorPane, .closeOtherEditorPanes, .focusEditorPane, .changeEditorOrientation:
            // The focused tab shows something else, or nothing: re-enter both
            // panes for `selectedRuntimeObject`. `.back` reuses each pane's
            // controller and rebinds only when the object changed, so a route
            // that left the object on screen alone — a reorder, a tab closed in
            // the background — costs nothing.
            if documentState.selectedRuntimeObject != nil {
                contentCoordinator.contextTrigger(.back)
                inspectorCoordinator.contextTrigger(.back)
            } else {
                contentCoordinator.contextTrigger(.placeholder)
                inspectorCoordinator.contextTrigger(.placeholder)
            }
        }
    }
}

// MARK: - Cross-scope sheet requests
//
// These two delegates exist because both events open a sheet that is owned
// by `MainCoordinator` (not by the originating sub-coordinator) — that's a
// scope crossing the selection route vocabulary intentionally does not
// model. All cross-pane navigation flows through `documentState.selectionRouter`.

extension MainCoordinator: InspectorCoordinator.Delegate {
    func inspectorCoordinator(
        _: InspectorCoordinator,
        requestSpecializationSheetFor object: RuntimeObject
    ) {
        contextTrigger(.beginSpecializationSheet(object))
    }
}

extension MainCoordinator: SpecializationCoordinator.Delegate {
    func specializationCoordinator(
        _: SpecializationCoordinator,
        didProduce specialized: RuntimeObject
    ) {
        documentState.selectionRouter.trigger(.selectAtRoot(specialized))
    }
}
