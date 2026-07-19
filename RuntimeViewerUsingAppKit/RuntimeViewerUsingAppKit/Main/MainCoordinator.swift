import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import RuntimeViewerMCPBridge
import LateResponders

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>, LateResponderRegistering {
    @Dependency(\.attachToProcessViewController) private var attachToProcessViewController

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
        super.init(windowController: .init(documentState: documentState), initialRoute: .main(.local))
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

            return .multiple(
                .show(rootWindowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root),
                .route(on: contentCoordinator, to: .placeholder),
                .route(on: inspectorCoordinator, to: .placeholder),
            )
        case .generationOptions(let sender):
            let viewController = GenerationOptionsViewController()
            let viewModel = GenerationOptionsViewModel(documentState: documentState, router: self)
            viewController.loadViewIfNeeded()
            viewController.setupBindings(for: viewModel)
            return .uxPopover(viewController, relativeTo: sender.bounds, of: sender, preferredEdge: .maxY, behavior: .transient)
        case .mcpStatus(let sender):
            let viewController = MCPStatusPopoverViewController()
            let viewModel = MCPStatusPopoverViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .uxPopover(viewController, relativeTo: sender.bounds, of: sender, preferredEdge: .maxY, behavior: .transient)
        case .backgroundIndexing(let sender):
            let viewController = BackgroundIndexingPopoverViewController()
            let viewModel = BackgroundIndexingPopoverViewModel(
                documentState: documentState,
                router: self
            )
            viewController.setupBindings(for: viewModel)
            return .uxPopover(viewController, relativeTo: sender.bounds, of: sender, preferredEdge: .maxY, behavior: .transient)
        case .attachToProcess:
            let viewController = attachToProcessViewController
            let viewModel = AttachToProcessViewModel(documentState: documentState, router: self)
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
        }
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
            assertionFailure(".switchEngine fired with an active route subscriber; engine switches must go through MainRoute.main")
        case .selectAtRoot(let object):
            contentCoordinator.contextTrigger(.root(object))
            inspectorCoordinator.contextTrigger(.root(.object(object)))
            // Sidebar visual sync is handled inside
            // `SidebarRuntimeObjectListViewModel` by observing
            // `documentState.$selectionStack` directly — no coordinator
            // routing is needed for a pure UI scroll-and-highlight.
        case .push(let object):
            contentCoordinator.contextTrigger(.next(object))
            inspectorCoordinator.contextTrigger(.next(.object(object)))
        case .pop:
            if documentState.selectionStack.isEmpty {
                contentCoordinator.contextTrigger(.placeholder)
                inspectorCoordinator.contextTrigger(.placeholder)
            } else {
                contentCoordinator.contextTrigger(.back)
                inspectorCoordinator.contextTrigger(.back)
            }
        case .backward, .forward, .jump:
            // History array unchanged — only the cursor moved. Re-enter
            // the text/runtimeObject scene for the new
            // `selectedRuntimeObject`. `.back` is the right vocabulary
            // because both panes reuse their existing controller and
            // just rebind to the cursor target (no push-transition
            // flash). `.jump` crosses several entries at once but is
            // otherwise identical — the cursor is all that moved.
            contentCoordinator.contextTrigger(.back)
            inspectorCoordinator.contextTrigger(.back)
        case .clear:
            contentCoordinator.contextTrigger(.placeholder)
            inspectorCoordinator.contextTrigger(.placeholder)
        case .switchImage(let node):
            contentCoordinator.contextTrigger(.placeholder)
            inspectorCoordinator.contextTrigger(.placeholder)
            if let node {
                sidebarCoordinator.contextTrigger(.clickedNode(node))
            } else {
                sidebarCoordinator.contextTrigger(.back)
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
