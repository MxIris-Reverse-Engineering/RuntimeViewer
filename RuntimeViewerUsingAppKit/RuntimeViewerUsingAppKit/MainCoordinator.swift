//
//  MainCoordinator.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

enum MainRoute: Routable {
    case initial
    case select(RuntimeObjectType)
    case inspect(InspectableType)
}

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

class MainCoordinator: SceneCoordinator<MainRoute, MainTransition> {
    let appServices: AppServices

    lazy var splitViewController = MainSplitViewController()

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices)

    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(windowController: .init(), initialRoute: .initial)
        sidebarCoordinator.delegate = self
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .initial:
            let viewModel = MainViewModel(appServices: appServices, router: unownedRouter)
            splitViewController.setupBindings(for: viewModel)
            return .multiple(.show(splitViewController), .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator))
        case let .select(runtimeObject):
            return .route(.root(runtimeObject), on: contentCoordinator)
        case let .inspect(inspectableType):
            return .route(.select(inspectableType), on: inspectorCoordinator)
        }
    }
}

extension MainCoordinator: SidebarCoordinatorDelegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case let .selectedNode(runtimeNamedNode):
            inspectorCoordinator.contextTrigger(.select(.node(runtimeNamedNode)))
        case let .selectedObject(runtimeObjectType):
            contentCoordinator.contextTrigger(.root(runtimeObjectType))
        default:
            break
        }
    }
}
