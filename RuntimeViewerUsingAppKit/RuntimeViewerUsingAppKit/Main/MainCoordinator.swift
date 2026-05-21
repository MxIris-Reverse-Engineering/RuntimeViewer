import AppKit
import RuntimeViewerCore
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

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(windowController: .init(documentState: documentState), initialRoute: .main(.local))
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .main(let runtimeEngine):
            documentState.runtimeEngine = runtimeEngine
            documentState.currentImageNode = nil
            sidebarCoordinator.removeFromParent()
            contentCoordinator.removeFromParent()
            inspectorCoordinator.removeFromParent()
            sidebarCoordinator = SidebarCoordinator(documentState: documentState)
            contentCoordinator = ContentCoordinator(documentState: documentState)
            inspectorCoordinator = InspectorCoordinator(documentState: documentState)
            inspectorCoordinator.delegate = self
            windowController.setupBindings(for: viewModel)
            return .multiple(
                .show(windowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root)
            )
        case .generationOptions(let sender):
            let viewController = GenerationOptionsViewController()
            let viewModel = GenerationOptionsViewModel(documentState: documentState, router: self)
            viewController.loadViewIfNeeded()
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .mcpStatus(let sender):
            let viewController = MCPStatusPopoverViewController()
            let viewModel = MCPStatusPopoverViewModel(documentState: documentState, router: self)
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .backgroundIndexing(let sender):
            let viewController = BackgroundIndexingPopoverViewController()
            let viewModel = BackgroundIndexingPopoverViewModel(
                documentState: documentState,
                router: self
            )
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .attachToProcess:
            let viewController = AttachToProcessViewController()
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
            windowController.splitViewController.setupSplitViewItems()
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

}

// MARK: - Cross-scope sheet requests
//
// These two delegates exist because both events open a sheet that is owned
// by `MainCoordinator` (not by the originating sub-coordinator) — that's a
// scope crossing `documentState` cannot model. Pure state-driven UI updates
// (sidebar, content, inspector navigation) live entirely in `documentState`
// subscriptions inside each sub-coordinator and do not need delegates.

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
        documentState.selectionStack = [specialized]
    }
}
