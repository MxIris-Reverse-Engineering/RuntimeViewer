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
import RuntimeViewerApplication

typealias MainTransition = SceneTransition<MainWindowController, MainSplitViewController>

class MainCoordinator: SceneCoordinator<MainRoute, MainTransition> {
    let appServices: AppServices

    let completeTransition: PublishRelay<SidebarRoute> = .init()

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices)

    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(windowController: .init(), initialRoute: .main(.shared))
        windowController.window?.title = "Runtime Viewer"
    }

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case let .main(runtimeListings):
            appServices.runtimeListings = runtimeListings
            sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)
            contentCoordinator = ContentCoordinator(appServices: appServices)
            inspectorCoordinator = InspectorCoordinator(appServices: appServices)
            let viewModel = MainViewModel(appServices: appServices, router: self, completeTransition: completeTransition.asObservable())
            windowController.setupBindings(for: viewModel)
            return .multiple(
                .show(windowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root),
                .route(on: contentCoordinator, to: .placeholder),
                .route(on: inspectorCoordinator, to: .root)
            )
        case let .select(runtimeObject):
            return .route(on: contentCoordinator, to: .root(runtimeObject))
        case let .inspect(inspectableType):
            return .route(on: inspectorCoordinator, to: .select(inspectableType))
        case .sidebarBack:
            return .route(on: sidebarCoordinator, to: .back)
        case .generationOptions(let sender):
            let viewController = GenerationOptionsViewController()
            let viewModel = GenerationOptionsViewModel(appServices: appServices, router: self)
            viewController.setupBindings(for: viewModel)
            return .presentOnRoot(viewController, mode: .asPopover(relativeToRect: sender.bounds, ofView: sender, preferredEdge: .maxY, behavior: .transient))
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

extension MainCoordinator: SidebarCoordinatorDelegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case let .selectedNode(runtimeNamedNode):
            inspectorCoordinator.contextTrigger(.select(.node(runtimeNamedNode)))
        case let .clickedNode(runtimeNamedNode):
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
        completeTransition.accept(route)
    }
}
