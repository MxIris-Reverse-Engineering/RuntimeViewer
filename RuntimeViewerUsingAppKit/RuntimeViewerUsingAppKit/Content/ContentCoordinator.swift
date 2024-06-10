//
//  EditorCoordinator.swift
//  RuntimeViewerUsingAppKit
//
//  Created by JH on 2024/6/3.
//

import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures

enum ContentRoute: Routable {
    case placeholder
    case root(RuntimeObjectType)
    case next(RuntimeObjectType)
    case back
}

typealias ContentTransition = Transition<Void, ContentNavigationController>

class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition> {
    let appServices: AppServices
    init(appServices: AppServices) {
        self.appServices = appServices
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }
    
    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(appServices: appServices, router: unownedRouter)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            return .set([contentPlaceholderViewController], animated: false)
        case .root(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appServices: appServices, router: unownedRouter)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .set([contentTextViewController], animated: false)
        case .next(let runtimeObjectType):
            let contentTextViewController = ContentTextViewController()
            let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObjectType, appServices: appServices, router: unownedRouter)
            contentTextViewController.setupBindings(for: contentTextViewModel)
            return .push(contentTextViewController, animated: true)
        case .back:
            return .pop(animated: true)
        }
    }
}
