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
            sidebarCoordinator.delegate = self
            contentCoordinator = ContentCoordinator(documentState: documentState)
            contentCoordinator.delegate = self
            inspectorCoordinator = InspectorCoordinator(documentState: documentState)
            inspectorCoordinator.delegate = self
            viewModel.completeTransition = sidebarCoordinator.rx.didCompleteTransition()
            windowController.setupBindings(for: viewModel)
            return .multiple(
                .show(windowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root),
                .route(on: contentCoordinator, to: .placeholder),
                .route(on: inspectorCoordinator, to: .placeholder)
            )
        case .select(let runtimeObject):
            sidebarCoordinator.programmaticallySelectObject(runtimeObject)
            return .none()
        case .sidebarBack:
            return .route(on: sidebarCoordinator, to: .back)
        case .contentBack:
            return .route(on: contentCoordinator, to: .back)
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
                router: self,
                coordinator: documentState.backgroundIndexingCoordinator
            )
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .loadFramework:
            return .none()
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

    private func updateContentStackDepth() {
        let hasBackStack = contentCoordinator.rootViewController.viewControllers.count >= 2
        viewModel.isContentStackDepthGreaterThanOne.accept(hasBackStack)
    }
}

// MARK: - Sidebar / Content / Inspector / Specialization delegate plumbing

extension MainCoordinator: SidebarCoordinator.Delegate {
    func sidebarCoordinator(
        _ coordinator: SidebarCoordinator,
        didSelectObject runtimeObject: RuntimeObject
    ) {
        documentState.selectedRuntimeObject = runtimeObject
        contentCoordinator.trigger(.root(runtimeObject))
    }

    func sidebarCoordinator(
        _ coordinator: SidebarCoordinator,
        didClickImageNode imageNode: RuntimeImageNode
    ) {
        documentState.currentImageNode = imageNode
    }

    func sidebarCoordinatorDidGoBack(_ coordinator: SidebarCoordinator) {
        documentState.currentImageNode = nil
        documentState.selectedRuntimeObject = nil
        contentCoordinator.trigger(.placeholder)
    }
}

extension MainCoordinator: ContentCoordinator.Delegate {
    func contentCoordinatorDidShowPlaceholder(_ coordinator: ContentCoordinator) {
        updateContentStackDepth()
        documentState.selectedRuntimeObject = nil
        inspectorCoordinator.trigger(.placeholder)
    }

    func contentCoordinator(
        _ coordinator: ContentCoordinator,
        didShowRoot runtimeObject: RuntimeObject
    ) {
        updateContentStackDepth()
        documentState.selectedRuntimeObject = runtimeObject
        inspectorCoordinator.trigger(.root(.object(runtimeObject)))
    }

    func contentCoordinator(
        _ coordinator: ContentCoordinator,
        didShowNext runtimeObject: RuntimeObject
    ) {
        updateContentStackDepth()
        documentState.selectedRuntimeObject = runtimeObject
        inspectorCoordinator.trigger(.next(.object(runtimeObject)))
    }

    func contentCoordinatorDidGoBack(_ coordinator: ContentCoordinator) {
        updateContentStackDepth()
        inspectorCoordinator.trigger(.back)
    }
}

extension MainCoordinator: InspectorCoordinator.Delegate {
    func inspectorCoordinator(
        _: InspectorCoordinator,
        requestSpecializationSheetFor object: RuntimeObject
    ) {
        contextTrigger(.beginSpecializationSheet(object))
    }

    func inspectorCoordinator(
        _: InspectorCoordinator,
        selectRuntimeObject object: RuntimeObject
    ) {
        contextTrigger(.select(object))
    }
}

extension MainCoordinator: SpecializationCoordinator.Delegate {
    func specializationCoordinator(
        _: SpecializationCoordinator,
        didProduce specialized: RuntimeObject
    ) {
        contextTrigger(.select(specialized))
    }
}
