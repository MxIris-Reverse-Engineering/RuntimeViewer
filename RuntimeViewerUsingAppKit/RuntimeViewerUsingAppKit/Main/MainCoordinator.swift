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

    lazy var sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)

    lazy var contentCoordinator = ContentCoordinator(appServices: appServices, delegate: self)

    lazy var inspectorCoordinator = InspectorCoordinator(appServices: appServices)

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(windowController: .init(), initialRoute: .main(.shared))
    }

    lazy var viewModel = MainViewModel(appServices: appServices, router: self, completeTransition: sidebarCoordinator.rx.didCompleteTransition())

    override func prepareTransition(for route: MainRoute) -> MainTransition {
        switch route {
        case let .main(runtimeEngine):
            appServices.runtimeEngine = runtimeEngine
            removeChild(sidebarCoordinator)
            removeChild(contentCoordinator)
            removeChild(inspectorCoordinator)
            sidebarCoordinator = SidebarCoordinator(appServices: appServices, delegate: self)
            contentCoordinator = ContentCoordinator(appServices: appServices, delegate: self)
            inspectorCoordinator = InspectorCoordinator(appServices: appServices)
            windowController.setupBindings(for: viewModel)
            return .multiple(
                .show(windowController.splitViewController),
                .set(sidebar: sidebarCoordinator, content: contentCoordinator, inspector: inspectorCoordinator),
                .route(on: sidebarCoordinator, to: .root),
                .route(on: contentCoordinator, to: .placeholder),
                .route(on: inspectorCoordinator, to: .placeholder)
            )
        case let .select(runtimeObject):
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
            
            break
        default:
            break
        }
    }
}

extension MainCoordinator: SidebarCoordinator.Delegate {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition route: SidebarRoute) {
        switch route {
        case .selectedNode(_):
            break
        case let .clickedNode(runtimeNamedNode):
            windowController.window?.title = runtimeNamedNode.name
        case let .selectedObject(runtimeObjectType):
//            windowController.window?.title = runtimeObjectType.name
            
            contentCoordinator.contextTrigger(.root(runtimeObjectType))
        case .back:
//            windowController.window?.title = "Runtime Viewer"
            contentCoordinator.contextTrigger(.placeholder)
        default:
            break
        }
    }
}

extension MainCoordinator: ContentCoordinator.Delegate {
    func contentCoordinator(_ contentCoordinator: ContentCoordinator, completeTransition route: ContentRoute) {
        if contentCoordinator.rootViewController.viewControllers.count < 2 {
            windowController.toolbarController.toolbar.removeItem(at: .Main.contentBack)
        } else if !windowController.toolbarController.toolbar.items.contains(where: { $0.itemIdentifier == .Main.contentBack }) {
            windowController.toolbarController.toolbar.insertItem(withItemIdentifier: .Main.contentBack, at: 0)
        }
        switch route {
        case .placeholder:
            inspectorCoordinator.contextTrigger(.placeholder)
        case .root(let runtimeObjectType):
            inspectorCoordinator.contextTrigger(.root(.object(runtimeObjectType)))
        case .next(let runtimeObjectType):
            inspectorCoordinator.contextTrigger(.next(.object(runtimeObjectType)))
        case .back:
            inspectorCoordinator.contextTrigger(.back)
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
