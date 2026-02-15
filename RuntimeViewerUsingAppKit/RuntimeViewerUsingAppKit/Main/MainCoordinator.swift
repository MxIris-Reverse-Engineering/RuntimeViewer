import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import LateResponders

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>, LateResponderRegistering {
    let documentState: DocumentState

    private lazy var sidebarCoordinator = SidebarCoordinator(documentState: documentState, delegate: self)

    private lazy var contentCoordinator = ContentCoordinator(documentState: documentState, delegate: self)

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
            documentState.currentImageName = nil
            sidebarCoordinator.removeFromParent()
            contentCoordinator.removeFromParent()
            inspectorCoordinator.removeFromParent()
            sidebarCoordinator = SidebarCoordinator(documentState: documentState, delegate: self)
            contentCoordinator = ContentCoordinator(documentState: documentState, delegate: self)
            inspectorCoordinator = InspectorCoordinator(documentState: documentState)
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
            return .route(on: contentCoordinator, to: .root(runtimeObject))
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

extension MainCoordinator: SidebarCoordinator.Delegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case .clickedNode(let imageNode):
            documentState.currentImageName = imageNode.name
        case .selectedObject(let runtimeObject):
            documentState.selectedRuntimeObject = runtimeObject
            contentCoordinator.trigger(.root(runtimeObject))
        case .back:
            documentState.currentImageName = nil
            documentState.selectedRuntimeObject = nil
            contentCoordinator.trigger(.placeholder)
        default:
            break
        }
    }
}

extension MainCoordinator: ContentCoordinator.Delegate {
    func contentCoordinator(_ contentCoordinator: ContentCoordinator, completeTransition route: ContentRoute) {
        let hasBackStack = contentCoordinator.rootViewController.viewControllers.count >= 2
        viewModel.isContentStackDepthGreaterThanOne.accept(hasBackStack)

        switch route {
        case .placeholder:
            documentState.selectedRuntimeObject = nil
            inspectorCoordinator.trigger(.placeholder)
        case .root(let runtimeObject):
            documentState.selectedRuntimeObject = runtimeObject
            inspectorCoordinator.trigger(.root(.object(runtimeObject)))
        case .next(let runtimeObject):
            documentState.selectedRuntimeObject = runtimeObject
            inspectorCoordinator.trigger(.next(.object(runtimeObject)))
        case .back:
            inspectorCoordinator.trigger(.back)
        }
    }
}
