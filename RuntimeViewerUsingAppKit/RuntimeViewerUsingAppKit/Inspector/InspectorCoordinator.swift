//
//  InspectorCoordinator.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorViewController>

class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    let appServices: AppServices

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .root:
            let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController])
        case let .select(inspectableType):
            return .none()
        }
    }
}
