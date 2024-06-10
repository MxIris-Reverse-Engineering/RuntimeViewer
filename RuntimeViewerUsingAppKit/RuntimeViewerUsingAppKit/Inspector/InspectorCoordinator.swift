//
//  InspectorCoordinator.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerArchitectures

enum InspectableType {
    case node(RuntimeNamedNode)
    case object(RuntimeObjectType)
}

enum InspectorRoutable: Routable {
    case root
    case select(InspectableType)
}

typealias InspectorTransition = Transition<Void, InspectorViewController>

class InspectorCoordinator: ViewCoordinator<InspectorRoutable, InspectorTransition> {
    let appServices: AppServices
    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .root)
    }
    
    override func prepareTransition(for route: InspectorRoutable) -> InspectorTransition {
        switch route {
        case .root:
            let viewModel = InspectorViewModel(appServices: appServices, router: unownedRouter)
            rootViewController.setupBindings(for: viewModel)
            return .none()
        case .select(let inspectableType):
            return .none()
        }
    }
}
