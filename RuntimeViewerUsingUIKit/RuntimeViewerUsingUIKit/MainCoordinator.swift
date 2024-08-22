#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

public enum MainRoute: Routable {
    case initial
    case select(RuntimeObjectType)
    case inspect(InspectableObject)
}

typealias MainTransition = Transition<MainSplitViewController>

class MainCoordinator: BaseCoordinator<MainRoute, MainTransition> {
    let appServices: AppServices

    let completeTransition: PublishRelay<SidebarRoute> = .init()

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices)

    lazy var compactSidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(style: .doubleColumn), initialRoute: nil)
        rootViewController.delegate = self
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .initial:
            let viewModel = MainViewModel(appServices: appServices, router: self)
            rootViewController.setupBindings(for: viewModel)
            return .multiple(.set(sidebarCoordinator, for: .primary), .set(contentCoordinator, for: .secondary), .set(sidebarCoordinator, for: .compact))
        case let .select(runtimeObject):
            return .multiple(.route(.root(runtimeObject), on: contentCoordinator), .showDetail(contentCoordinator))
        case let .inspect(inspectableType):
            return .route(.root(inspectableType), on: inspectorCoordinator)
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

extension MainCoordinator: UISplitViewControllerDelegate {
    func splitViewController(_ svc: UISplitViewController,
                             topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column)
        -> UISplitViewController.Column {
        return .primary
    }
}

extension MainCoordinator: SidebarCoordinatorDelegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case let .selectedNode(runtimeNamedNode):
            inspectorCoordinator.trigger(.root(.node(runtimeNamedNode)))
        case let .clickedNode(runtimeNamedNode):
            break
        case let .selectedObject(runtimeObjectType):
            trigger(.select(runtimeObjectType), with: .init(animated: false))
        case .back:
            contentCoordinator.trigger(.placeholder)
        default:
            break
        }
        completeTransition.accept(route)
    }
}

#endif
