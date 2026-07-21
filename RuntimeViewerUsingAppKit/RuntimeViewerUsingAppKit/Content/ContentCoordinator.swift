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

    /// Object the text scene is currently bound to. `.back` re-entries
    /// (cursor moves, tab routes) skip rebinding when the object is unchanged:
    /// closing a background tab re-enters the text scene without changing the
    /// visible object, and rebuilding the `ContentTextViewModel` then only
    /// wastes a full interface regeneration and tears down a ViewModel whose
    /// fetch is still in flight. Explicit selections (`.root` / `.next`)
    /// still rebind unconditionally so re-clicking a row recovers from a
    /// failed generation (`catchAndReturn` terminates the old ViewModel's
    /// stream).
    private var boundRuntimeObject: RuntimeObject?

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            return enterPlaceholderScene()
        case .root(let runtimeObject):
            return enterTextScene(for: runtimeObject, forceRebind: true)
        case .next(let runtimeObject):
            return enterTextScene(for: runtimeObject, forceRebind: true)
        case .back:
            if let selected = documentState.selectedRuntimeObject {
                return enterTextScene(for: selected, forceRebind: false)
            } else {
                return enterPlaceholderScene()
            }
        }
    }

    private var isCurrentTextScene: Bool { currentScene == .text }
    
    private func enterPlaceholderScene() -> ContentTransition {
        guard currentScene != .placeholder else { return .none() }
        currentScene = .placeholder
        boundRuntimeObject = nil
        return .set([placeholderViewController], animated: false)
    }

    private func enterTextScene(for runtimeObject: RuntimeObject, forceRebind: Bool) -> ContentTransition {
        rebindTextViewController(for: runtimeObject, forceRebind: forceRebind)
        guard !isCurrentTextScene else { return .none() }
        currentScene = .text
        return .set([textViewController], animated: false)
    }

    private func rebindTextViewController(for runtimeObject: RuntimeObject, forceRebind: Bool) {
        if !isCurrentTextScene {
            textViewController = .init()
            boundRuntimeObject = nil
        }
        guard forceRebind || boundRuntimeObject != runtimeObject else { return }
        boundRuntimeObject = runtimeObject
        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
        textViewController.setupBindings(for: viewModel)
        textViewController.loadViewIfNeeded()
    }
}
