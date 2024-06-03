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
}
