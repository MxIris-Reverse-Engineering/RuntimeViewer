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
    case sidebarBack
}

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>


class MainCoordinator: SceneCoordinator<MainRoute, MainTransition> {
    let appServices: AppServices

    lazy var splitViewController = MainSplitViewController()

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices)

    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(windowController: .init(), initialRoute: .initial)
        windowController.window?.title = "Runtime Viewer"
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .initial:
            let viewModel = MainViewModel(appServices: appServices, router: unownedRouter)
            splitViewController.setupBindings(for: viewModel)
            windowController.setupBindings(for: viewModel)
            return .multiple(.show(splitViewController), .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator))
        case let .select(runtimeObject):
            return .route(on: contentCoordinator, to: .root(runtimeObject))
        case let .inspect(inspectableType):
            return .route(on: inspectorCoordinator, to: .select(inspectableType))
        case .sidebarBack:
            return .route(on: sidebarCoordinator, to: .back)
        }
    }
    
    override func completeTransition(for route: MainRoute) {
        switch route {
        case .initial:
            splitViewController.setupSplitViewItems()
        default:
            break
        }
    }
}

extension MainCoordinator: SidebarCoordinatorDelegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case let .selectedNode(runtimeNamedNode):
            inspectorCoordinator.contextTrigger(.select(.node(runtimeNamedNode)))
        case .clickedNode(let runtimeNamedNode):
            windowController.window?.title = runtimeNamedNode.name
        case let .selectedObject(runtimeObjectType):
            contentCoordinator.contextTrigger(.root(runtimeObjectType))
        case .back:
            windowController.window?.title = "Runtime Viewer"
            contentCoordinator.contextTrigger(.placeholder)
        default:
            break
        }
        windowController.toolbarController.backItem.backButton.isHidden = sidebarCoordinator.rootViewController.viewControllers.count < 2
    }
}
