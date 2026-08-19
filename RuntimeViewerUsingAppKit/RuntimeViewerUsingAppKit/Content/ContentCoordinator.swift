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
    /// `ContentTextViewModel`. This avoids the push transition flash on
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

    /// Which content view is in use. Recorded so that flipping Settings › Editor swaps the
    /// view on the next selection rather than only after the scene has been left and
    /// re-entered, which from the user's side would look like the setting did nothing.
    private enum EditorKind {
        case textView
        case sourceEditor
    }

    private var currentEditorKind: EditorKind?

    private lazy var textViewController: UXKitViewController<ContentTextViewModel> = makeTextViewController(kind: desiredEditorKind())

    /// Anything that stops the Xcode-backed editor from loading — the setting being off, no
    /// Xcode installed, an arm64e build, a missing bridge bundle — resolves to the
    /// `NSTextView` implementation, which is the shipping behaviour.
    private func desiredEditorKind() -> EditorKind {
        @Dependency(\.sourceEditorLoader) var sourceEditorLoader
        guard sourceEditorLoader.isEnabledByUser, sourceEditorLoader.isAvailable else { return .textView }
        return .sourceEditor
    }

    /// Both content views bind the same `ContentTextViewModel`, so choosing between them is
    /// the whole of the switch.
    private func makeTextViewController(kind: EditorKind) -> UXKitViewController<ContentTextViewModel> {
        switch kind {
        case .textView: ContentTextViewController()
        case .sourceEditor: ContentSourceEditorViewController()
        }
    }

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
        let didReplaceViewController = rebindTextViewController(for: runtimeObject, forceRebind: forceRebind)
        // A replacement has to be installed even when the text scene is already showing:
        // otherwise the freshly built view controller is bound but never displayed.
        guard !isCurrentTextScene || didReplaceViewController else { return .none() }
        currentScene = .text
        return .set([textViewController], animated: false)
    }

    /// - Returns: whether the view controller itself was replaced.
    @discardableResult
    private func rebindTextViewController(for runtimeObject: RuntimeObject, forceRebind: Bool) -> Bool {
        let desiredKind = desiredEditorKind()
        var didReplaceViewController = false
        if !isCurrentTextScene || currentEditorKind != desiredKind {
            textViewController = makeTextViewController(kind: desiredKind)
            currentEditorKind = desiredKind
            boundRuntimeObject = nil
            didReplaceViewController = true
        }
        guard forceRebind || boundRuntimeObject != runtimeObject else { return didReplaceViewController }
        boundRuntimeObject = runtimeObject
        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, documentState: documentState, router: self)
        textViewController.setupBindings(for: viewModel)
        textViewController.loadViewIfNeeded()
        return didReplaceViewController
    }
}
