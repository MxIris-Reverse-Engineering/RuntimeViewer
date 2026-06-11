import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias ContentTransition = Transition<Void, ContentNavigationController>

final class ContentCoordinator: ViewCoordinator<ContentRoute, ContentTransition> {
    /// Which child VC the navigation is currently showing. We only `set` the
    /// navigation stack when this changes; switching the active
    /// `RuntimeObject` within the `.text` scene reuses the existing
    /// `ContentTextViewController` and just rebinds it to a fresh
    /// `ContentTextViewModel`. This avoids the UXKit push transition flash on
    /// every sidebar selection.
    ///
    @CaseCheckable
    private enum Scene {
        case initial
        case placeholder
        case text
    }

    let documentState: DocumentState

    private var currentScene: Scene = .initial

    private lazy var placeholderViewController: ContentPlaceholderViewController = {
        let viewController = ContentPlaceholderViewController()
        let viewModel = ContentPlaceholderViewModel(documentState: documentState, router: self)
        viewController.setupBindings(for: viewModel)
        viewController.loadViewIfNeeded()
        return viewController
    }()

    private lazy var textViewController: ContentTextViewController = .init()

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            return enterPlaceholderScene()
        case .root(let runtimeObject):
            return enterTextScene(for: runtimeObject)
        case .next(let runtimeObject):
            return enterTextScene(for: runtimeObject)
        case .back:
            if let selected = documentState.selectedRuntimeObject {
                return enterTextScene(for: selected)
            } else {
                return enterPlaceholderScene()
            }
        }
    }

    private var isCurrentTextScene: Bool { currentScene == .text }
    
    private func enterPlaceholderScene() -> ContentTransition {
        guard currentScene != .placeholder else { return .none() }
        currentScene = .placeholder
        return .set([placeholderViewController], animated: false)
    }

    private func enterTextScene(for runtimeObject: RuntimeObject) -> ContentTransition {
        rebindTextViewController(for: runtimeObject)
        guard !isCurrentTextScene else { return .none() }
        currentScene = .text
        return .set([textViewController], animated: false)
    }

    private func rebindTextViewController(for runtimeObject: RuntimeObject) {
        if !isCurrentTextScene {
            textViewController = .init()
        }
        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
        textViewController.setupBindings(for: viewModel)
        textViewController.loadViewIfNeeded()
    }
}
