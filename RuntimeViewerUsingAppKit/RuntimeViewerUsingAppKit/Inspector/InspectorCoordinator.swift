//
//  InspectorCoordinator.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerUI
import RuntimeViewerCore
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias InspectorTransition = Transition<Void, InspectorNavigationController>

class InspectorCoordinator: ViewCoordinator<InspectorRoute, InspectorTransition> {
    let appServices: AppServices

    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: nil)
    }

    override func prepareTransition(for route: InspectorRoute) -> InspectorTransition {
        switch route {
        case .placeholder:
            let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return .set([viewController], animated: false)
        case let .root(inspectableObject):
            return .set([makeTransition(for: inspectableObject)], animated: false)
        case let .next(inspectableObject):
            return .push(makeTransition(for: inspectableObject), animated: false)
        case .back:
            return .pop(animated: false)
        }
    }

    func makeTransition(for inspectableObject: InspectableObject) -> UXViewController {
        switch inspectableObject {
        case let .node(runtimeNamedNode):
            let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
            let viewController = InspectorPlaceholderViewController()
            viewController.setupBindings(for: viewModel)
            return viewController
        case let .object(runtimeObjectType):
            switch runtimeObjectType {
            case let .class(named):
                let viewModel = InspectorClassViewModel(runtimeClassName: named, appServices: appServices, router: self)
                let viewController = InspectorClassViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
            case let .protocol(named):
                let viewModel = InspectorPlaceholderViewModel(appServices: appServices, router: self)
                let viewController = InspectorPlaceholderViewController()
                viewController.setupBindings(for: viewModel)
                return viewController
            }
        }
    }
}
