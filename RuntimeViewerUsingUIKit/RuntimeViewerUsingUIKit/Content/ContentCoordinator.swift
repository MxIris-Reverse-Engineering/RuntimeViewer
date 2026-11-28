#if canImport(UIKit)

import UIKit
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerArchitectures
#if RUNTIME_VIEWER_SOURCE_EDITOR
import RuntimeViewerSourceEditorBridge
#endif

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
            return .set([makeContentViewController(for: runtimeObjectType)], animation: .default)
        case .rootHighlighting(let runtimeObjectType, let highlightRequest):
            return .set([makeContentViewController(for: runtimeObjectType, highlightRequest: highlightRequest)], animation: .default)
        case .next(let runtimeObjectType):
            return .push(makeContentViewController(for: runtimeObjectType), animation: .default)
        case .nextHighlighting(let runtimeObjectType, let highlightRequest):
            return .push(makeContentViewController(for: runtimeObjectType, highlightRequest: highlightRequest), animation: .default)
        case .image:
            // Sent by the macOS editor pane's jump bar alone; this app has none.
            return .none()
        case .back:
            return .pop(animation: .default)
        }
    }

    /// The page that shows a runtime object's interface: in SourceEditor where this build carries it
    /// — the iOS app on Apple silicon or a device, with the frameworks downloaded — and in the text
    /// view anywhere else. Both bind the same `ContentTextViewModel`.
    private func makeContentViewController(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil) -> UIViewController {
        let contentTextViewModel = ContentTextViewModel(runtimeObject: runtimeObject, highlightRequest: highlightRequest, documentState: documentState, router: self)
        #if RUNTIME_VIEWER_SOURCE_EDITOR
        // The factory rather than the provider: this coordinator is not main-actor isolated, and
        // whether the bridge was compiled with SourceEditor is a constant of the build.
        if SourceEditorBridgeFactory.isAvailable {
            let contentSourceEditorViewController = ContentSourceEditorViewController()
            contentSourceEditorViewController.setupBindings(for: contentTextViewModel)
            return contentSourceEditorViewController
        }
        #endif
        let contentTextViewController = ContentTextViewController()
        contentTextViewController.setupBindings(for: contentTextViewModel)
        return contentTextViewController
    }
}

#endif
