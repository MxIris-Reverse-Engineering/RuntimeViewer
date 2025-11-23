import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

final class MainCoordinator: SceneCoordinator<MainRoute, MainTransition> {
    let appServices: AppServices

    private lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    private lazy var contentCoordinator = ContentCoordinator(appServices: appServices, delegate: self)

    private lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    private lazy var viewModel = MainViewModel(appServices: appServices, router: self)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(windowController: .init(), initialRoute: .main(.shared))
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .main(let runtimeEngine):
            appServices.runtimeEngine = runtimeEngine
            removeChild(sidebarCoordinator)
            removeChild(contentCoordinator)
            removeChild(inspectorCoordinator)
            sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)
            contentCoordinator = ContentCoordinator(appServices: appServices, delegate: self)
            inspectorCoordinator = InspectorCoordinator(appServices: appServices)
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
//        case let .inspect(inspectableType):
//            return .route(on: inspectorCoordinator, to: .select(inspectableType))
        case .sidebarBack:
            return .route(on: sidebarCoordinator, to: .back)
        case .contentBack:
            return .route(on: contentCoordinator, to: .back)
        case .generationOptions(let sender):
            let viewController = GenerationOptionsViewController()
            let viewModel = GenerationOptionsViewModel(appServices: appServices, router: self)
            viewController.loadViewIfNeeded()
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
        case .loadFramework:
            return .none()
        case .attachToProcess:
            let viewController = AttachToProcessViewController()
            let viewModel = AttachToProcessViewModel(appServices: appServices, router: self)
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
}

extension MainCoordinator: SidebarCoordinator.Delegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case .selectedNode:
            break
        case .clickedNode(let runtimeNamedNode):
            windowController.window?.title = runtimeNamedNode.name
        case .selectedObject(let runtimeObjectType):
            contentCoordinator.trigger(.root(runtimeObjectType))
        case .back:
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
            inspectorCoordinator.trigger(.placeholder)
        case .root(let runtimeObjectType):
            inspectorCoordinator.trigger(.root(.object(runtimeObjectType)))
        case .next(let runtimeObjectType):
            inspectorCoordinator.trigger(.next(.object(runtimeObjectType)))
        case .back:
            inspectorCoordinator.trigger(.back)
        }
    }
}

extension NSToolbar {
    func removeItem(at itemIdentifier: NSToolbarItem.Identifier) {
        if let index = items.firstIndex(where: { $0.itemIdentifier == itemIdentifier }) {
            removeItem(at: index)
        }
    }
}
