#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures

typealias ContentTransition = NavigationTransition

class ContentCoordinator: NavigationCoordinator<ContentRoute> {
    let documentState: DocumentState

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            let contentPlaceholderViewController = ContentPlaceholderViewController()
            let contentPlaceholderViewModel = ContentPlaceholderViewModel(documentState: documentState, router: self)
            contentPlaceholderViewController.setupBindings(for: contentPlaceholderViewModel)
            return .set([contentPlaceholderViewController], animation: nil)
        case .root(let runtimeObjectType):
            return .set([makeTextViewController(for: runtimeObjectType)], animation: .default)
        case .rootHighlighting(let runtimeObjectType, let highlightRequest):
            return .set([makeTextViewController(for: runtimeObjectType, highlightRequest: highlightRequest)], animation: .default)
        case .next(let runtimeObjectType):
            return .push(makeTextViewController(for: runtimeObjectType), animation: .default)
        case .nextHighlighting(let runtimeObjectType, let highlightRequest):
            return .push(makeTextViewController(for: runtimeObjectType, highlightRequest: highlightRequest), animation: .default)
        case .back:
            return .pop(animation: .default)
        }
    }

    private func makeTextViewController(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil) -> ContentTextViewController {
        let contentTextViewController = ContentTextViewController()
        let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObject, highlightRequest: highlightRequest, documentState: documentState, router: self)
        contentTextViewController.setupBindings(for: contentTextViewModel)
        return contentTextViewController
    }
}

#endif
