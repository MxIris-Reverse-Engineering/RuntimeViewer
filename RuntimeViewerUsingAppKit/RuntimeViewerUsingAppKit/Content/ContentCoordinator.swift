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

    /// The editor pane this coordinator shows the content of: one coordinator per pane.
    let editorPaneID: EditorPane.ID

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

    private lazy var textViewController: BaseViewController<ContentTextViewModel> = makeTextViewController(kind: desiredEditorKind())

    /// A build compiled without SourceEditor — any build without the reconstructed frameworks,
    /// and the Intel half of a universal one — uses the `NSTextView` implementation.
    private func desiredEditorKind() -> EditorKind {
        @Dependency(\.sourceEditorBridgeProvider) var sourceEditorBridgeProvider
        guard sourceEditorBridgeProvider.isAvailable else { return .textView }
        return .sourceEditor
    }

    /// Both content views bind the same `ContentTextViewModel`, so choosing between them is
    /// the whole of the switch.
    private func makeTextViewController(kind: EditorKind) -> BaseViewController<ContentTextViewModel> {
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

    init(documentState: DocumentState, editorPaneID: EditorPane.ID) {
        self.documentState = documentState
        self.editorPaneID = editorPaneID
        super.init(rootViewController: .init(nibName: nil, bundle: nil), initialRoute: .placeholder)
    }

    override func prepareTransition(for route: ContentRoute) -> ContentTransition {
        switch route {
        case .placeholder:
            return enterPlaceholderScene()
        case .root(let runtimeObject):
            return enterTextScene(for: runtimeObject, forceRebind: true)
        case .rootHighlighting(let runtimeObject, let highlightRequest):
            return enterTextScene(for: runtimeObject, highlightRequest: highlightRequest, forceRebind: true)
        case .next(let runtimeObject):
            return enterTextScene(for: runtimeObject, forceRebind: true)
        case .nextHighlighting(let runtimeObject, let highlightRequest):
            return enterTextScene(for: runtimeObject, highlightRequest: highlightRequest, forceRebind: true)
        case .back:
            if let object = documentState.editorArea[editorPaneID]?.activeTab.object {
                return enterTextScene(for: object, forceRebind: false)
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

    private func enterTextScene(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, forceRebind: Bool) -> ContentTransition {
        let didReplaceViewController = rebindTextViewController(for: runtimeObject, highlightRequest: highlightRequest, forceRebind: forceRebind)
        // A replacement has to be installed even when the text scene is already showing:
        // otherwise the freshly built view controller is bound but never displayed.
        guard !isCurrentTextScene || didReplaceViewController else { return .none() }
        currentScene = .text
        return .set([textViewController], animated: false)
    }

    /// - Returns: whether the view controller itself was replaced.
    @discardableResult
    private func rebindTextViewController(for runtimeObject: RuntimeObject, highlightRequest: ContentHighlightRequest? = nil, forceRebind: Bool) -> Bool {
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
        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, highlightRequest: highlightRequest, editorPaneID: editorPaneID, documentState: documentState, router: self)
        textViewController.setupBindings(for: viewModel)
        textViewController.loadViewIfNeeded()
        return didReplaceViewController
    }
}
