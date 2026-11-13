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
        /// An image chosen in the jump bar, before any of its objects (proposal `editor-jump-bar`).
        case image
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

    /// The image scene's view controller, kept like the text scene's and bound to a new
    /// `ContentImageViewModel` for each image.
    private lazy var imageViewController = ContentImageViewController()

    /// The image the image scene is bound to. A `.back` re-entry of the same image — a tab switch,
    /// a pane that did not change — keeps the binding, so its indexing is not asked about again.
    private var boundImagePath: String?

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
    private var boundEntry: NavigationEntry?

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
        case .image(let imagePath):
            return enterImageScene(for: imagePath, forceRebind: true)
        case .back:
            switch documentState.editorArea[editorPaneID]?.activeTab.currentEntry?.content {
            case .object(let object, _)?:
                return enterTextScene(for: object, forceRebind: false)
            case .image(let imagePath)?:
                return enterImageScene(for: imagePath, forceRebind: false)
            case nil:
                return enterPlaceholderScene()
            }
        }
    }

    /// Shows the image page for `imagePath`. A route that chose the image binds it afresh — choosing
    /// it again tries again after a failure; re-entering the same image keeps what is on screen.
    private func enterImageScene(for imagePath: String, forceRebind: Bool) -> ContentTransition {
        if forceRebind || currentScene != .image || boundImagePath != imagePath {
            boundImagePath = imagePath
            let viewModel = ContentImageViewModel(imagePath: imagePath, documentState: documentState, router: self)
            imageViewController.setupBindings(for: viewModel)
            imageViewController.loadViewIfNeeded()
        }
        guard currentScene != .image else { return .none() }
        currentScene = .image
        boundEntry = nil
        return .set([imageViewController], animated: false)
    }

    private var isCurrentTextScene: Bool { currentScene == .text }
    
    private func enterPlaceholderScene() -> ContentTransition {
        guard currentScene != .placeholder else { return .none() }
        currentScene = .placeholder
        boundEntry = nil
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
            boundEntry = nil
            didReplaceViewController = true
        }
        // The router has put the entry on the pane's active tab before the route got here; its
        // language is the one the object is to be shown in.
        let interfaceLanguage = documentState.editorArea[editorPaneID]?.activeTab.currentEntry.flatMap { $0.object == runtimeObject ? $0.interfaceLanguage : nil }
        let entry = NavigationEntry(object: runtimeObject, interfaceLanguage: interfaceLanguage)
        guard forceRebind || boundEntry != entry else { return didReplaceViewController }
        boundEntry = entry
        let viewModel = ContentTextViewModel(runtimeObject: runtimeObject, interfaceLanguage: interfaceLanguage, highlightRequest: highlightRequest, editorPaneID: editorPaneID, documentState: documentState, router: self)
        textViewController.setupBindings(for: viewModel)
        textViewController.loadViewIfNeeded()
        return didReplaceViewController
    }
}
