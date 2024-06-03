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

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices)
    lazy var contentCoordinator = ContentCoordinator(appServices: appServices)
    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)
    lazy var splitViewController = MainSplitViewController()
    
    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(windowController: .init(), initialRoute: .initial)
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case .initial:
            let viewModel = MainViewModel(appServices: appServices, router: unownedRouter)
            splitViewController.setupBindings(for: viewModel)
            return .multiple(.show(splitViewController), .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator))
        case .select(let runtimeObject):
            return .route(.root(runtimeObject), on: contentCoordinator)
        case .inspect(let inspectableType):
            return .route(.select(inspectableType), on: inspectorCoordinator)
        }
    }
}




