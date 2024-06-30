//
//  SidebarCoordinator.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias SidebarTransition = Transition<Void, SidebarNavigationController>

protocol SidebarCoordinatorDelegate: AnyObject {
    func sidebarCoordinator(_ sidebarCoordinator: SidebarCoordinator, completeTransition: SidebarRoute)
}

class SidebarCoordinator: ViewCoordinator<SidebarRoute, SidebarTransition> {
    let appServices: AppServices

    weak var delegate: SidebarCoordinatorDelegate?

    init(appServices: AppServices, delegate: SidebarCoordinatorDelegate? = nil) {
        self.appServices = appServices
        self.delegate = delegate
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: SidebarRoute) -> SidebarTransition {
        switch route {
        case .root:
            let viewController = SidebarRootViewController()
            let viewModel = SidebarRootViewModel(appServices: appServices, router: self)
            viewController.setupBindings(for: viewModel)
            return .push(viewController, animated: false)
        case let .clickedNode(clickedNode):
            let imageViewController = SidebarImageViewController()
            let imageViewModel = SidebarImageViewModel(node: clickedNode, appServices: appServices, router: self)
            imageViewController.setupBindings(for: imageViewModel)
            return .push(imageViewController, animated: true)
        case .back:
            return .pop(animated: true)
        default:
            return .none()
        }
    }

    override func completeTransition(for route: SidebarRoute) {
        delegate?.sidebarCoordinator(self, completeTransition: route)
    }
}
