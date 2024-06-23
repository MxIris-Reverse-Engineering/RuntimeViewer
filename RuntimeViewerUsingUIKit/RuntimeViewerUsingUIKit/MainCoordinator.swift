#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

public enum MainRoute: Routable {
    case initial
    case select(RuntimeObjectType)
    case inspect(InspectableType)
}

typealias MainTransition = Transition<MainSplitViewController>

class MainCoordinator: BaseCoordinator<MainRoute, MainTransition> {
    let appServices: AppServices

    let completeTransition: PublishRelay<SidebarRoute> = .init()

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices)

    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .initial:
            let viewModel = MainViewModel(appServices: appServices, router: self)
            rootViewController.setupBindings(for: viewModel)
            return .multiple(.set(sidebarCoordinator, for: .primary), .set(contentCoordinator, for: .secondary))
        case let .select(runtimeObject):
            return .multiple(.showDetail(contentCoordinator), .route(.root(runtimeObject), on: contentCoordinator))
        case let .inspect(inspectableType):
            return .route(.select(inspectableType), on: inspectorCoordinator)
        }
    }

    override func completeTransition(for route: MainRoute) {
//        switch route {
//        case .initial:
//            windowController.splitViewController.setupSplitViewItems()
//        default:
//            break
//        }
    }
}

extension MainCoordinator: SidebarCoordinatorDelegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case let .selectedNode(runtimeNamedNode):
            inspectorCoordinator.trigger(.select(.node(runtimeNamedNode)))
        case let .clickedNode(runtimeNamedNode):
            break
        case let .selectedObject(runtimeObjectType):
            trigger(.select(runtimeObjectType))
        case .back:
            contentCoordinator.trigger(.placeholder)
        default:
            break
        }
        completeTransition.accept(route)
    }
}

#endif
