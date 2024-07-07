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

//    let completeTransition: PublishRelay<SidebarRoute> = .init()

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices, delegate: self)

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
            removeChild(sidebarCoordinator)
            removeChild(contentCoordinator)
            removeChild(inspectorCoordinator)
            sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)
            contentCoordinator = ContentCoordinator(appServices: appServices, delegate: self)
            inspectorCoordinator = InspectorCoordinator(appServices: appServices)
            let viewModel = MainViewModel(appServices: appServices, router: self, completeTransition: sidebarCoordinator.rx.didCompleteTransition())
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
        case .contentBack:
            return .route(on: contentCoordinator, to: .back)
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
            
            break
        default:
            break
        }
    }
}

extension MainCoordinator: SidebarCoordinator.Delegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case let .selectedNode(runtimeNamedNode):
            inspectorCoordinator.contextTrigger(.select(.node(runtimeNamedNode)))
        case let .clickedNode(runtimeNamedNode):
            windowController.window?.title = runtimeNamedNode.name
        case let .selectedObject(runtimeObjectType):
//            windowController.window?.title = runtimeObjectType.name
            inspectorCoordinator.contextTrigger(.select(.object(runtimeObjectType)))
            contentCoordinator.contextTrigger(.root(runtimeObjectType))
        case .back:
//            windowController.window?.title = "Runtime Viewer"
            contentCoordinator.contextTrigger(.placeholder)
        default:
            break
        }
//        windowController.toolbarController.sidebarBackItem.backButton.isHidden = sidebarCoordinator.rootViewController.viewControllers.count < 2
    }
}

extension MainCoordinator: ContentCoordinator.Delegate {
    func contentCoordinator(_ contentCoordinator: ContentCoordinator, completeTransition route: ContentRoute) {
        if contentCoordinator.rootViewController.viewControllers.count < 2 {
            windowController.toolbarController.toolbar.removeItem(at: .Main.contentBack)
        } else {
            windowController.toolbarController.toolbar.insertItem(withItemIdentifier: .Main.contentBack, at: 0)
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
