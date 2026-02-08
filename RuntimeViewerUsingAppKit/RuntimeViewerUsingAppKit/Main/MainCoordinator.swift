import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication
import LateResponders

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition>, LateResponderRegistering {
    let appState: AppState

    private lazy var sidebarCoordinator = SidebarCoordinator(appState: appState, delegate: self)

    private lazy var contentCoordinator = ContentCoordinator(appState: appState, delegate: self)

    private lazy var inspectorCoordinator = InspectorCoordinator(appState: appState)

    private lazy var viewModel = MainViewModel(appState: appState, router: self)
    
    private(set) lazy var lateResponderRegistry = LateResponderRegistry()

    init(appState: AppState) {
        self.appState = appState
        super.init(windowController: .init(appState: appState), initialRoute: .main(.shared))
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .main(let runtimeEngine):
            appState.runtimeEngine = runtimeEngine
            appState.currentImageName = nil
            sidebarCoordinator.removeFromParent()
            contentCoordinator.removeFromParent()
            inspectorCoordinator.removeFromParent()
            sidebarCoordinator = SidebarCoordinator(appState: appState, delegate: self)
            contentCoordinator = ContentCoordinator(appState: appState, delegate: self)
            inspectorCoordinator = InspectorCoordinator(appState: appState)
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
            let viewModel = GenerationOptionsViewModel(appState: appState, router: self)
            viewController.loadViewIfNeeded()
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .loadFramework:
            return .none()
        case .attachToProcess:
            let viewController = AttachToProcessViewController()
            let viewModel = AttachToProcessViewModel(appState: appState, router: self)
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
            appState.currentImageName = imageNode.name
        case .selectedObject(let runtimeObject):
            appState.selectedRuntimeObject = runtimeObject
            contentCoordinator.trigger(.root(runtimeObject))
        case .back:
            appState.currentImageName = nil
            appState.selectedRuntimeObject = nil
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
            appState.selectedRuntimeObject = nil
            inspectorCoordinator.trigger(.placeholder)
        case .root(let runtimeObject):
            appState.selectedRuntimeObject = runtimeObject
            inspectorCoordinator.trigger(.root(.object(runtimeObject)))
        case .next(let runtimeObject):
            appState.selectedRuntimeObject = runtimeObject
            inspectorCoordinator.trigger(.next(.object(runtimeObject)))
        case .back:
            inspectorCoordinator.trigger(.back)
        }
    }
}
