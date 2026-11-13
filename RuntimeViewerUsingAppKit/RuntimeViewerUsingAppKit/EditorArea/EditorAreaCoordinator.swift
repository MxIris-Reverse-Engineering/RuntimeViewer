import AppKit
import RuntimeViewerCore
import RuntimeViewerUI
import RuntimeViewerArchitectures
import RuntimeViewerApplication

typealias EditorAreaTransition = Transition<Void, EditorAreaViewController>

/// The editor area's coordinator: one `ContentCoordinator` and one `EditorPaneViewController` per
/// editor pane of `DocumentState.editorArea`, arranged by `EditorAreaViewController`.
///
/// `MainCoordinator.fanOut` hands it every `SelectionRoute` that reaches the editor area, after
/// the route has changed the document (`.apply`). It first makes the panes the area now holds and
/// lets go of the ones it no longer holds, then arranges them, then shows each pane's active tab:
/// the pane the route went to the way the route asks — a new tab starts the pane's scene over, a
/// Find hit is revealed — and every other pane by re-entering its tab (`.back`), which costs nothing
/// when the pane still shows the same object.
final class EditorAreaCoordinator: ViewCoordinator<EditorAreaRoute, EditorAreaTransition> {
    let documentState: DocumentState

    private struct Pane {
        let contentCoordinator: ContentCoordinator
        let viewController: EditorPaneViewController
    }

    private var panes: [EditorPane.ID: Pane] = [:]

    private lazy var viewModel = EditorAreaViewModel(documentState: documentState, router: self)

    init(documentState: DocumentState) {
        self.documentState = documentState
        super.init(rootViewController: EditorAreaViewController(), initialRoute: .sync)
    }

    override func prepareTransition(for route: EditorAreaRoute) -> EditorAreaTransition {
        if rootViewController.viewModel == nil {
            rootViewController.setupBindings(for: viewModel)
        }
        switch route {
        case .sync:
            synchronize(after: nil)
        case .apply(let selectionRoute):
            synchronize(after: selectionRoute)
        }
        return .none()
    }

    /// Reset Editor Sizes: only the views change, so it goes straight to the view controller.
    func resetEditorSizes() {
        rootViewController.resetSizes()
    }

    private func synchronize(after selectionRoute: SelectionRoute?) {
        let editorArea = documentState.editorArea

        for (paneID, pane) in panes where editorArea[paneID] == nil {
            pane.contentCoordinator.removeFromParent()
            panes[paneID] = nil
        }
        for paneID in editorArea.layout.paneIDs where panes[paneID] == nil {
            panes[paneID] = makePane(paneID)
        }

        rootViewController.apply(layout: editorArea.layout, panes: panes.mapValues(\.viewController))

        let targetedRoute = selectionRoute.flatMap(Self.contentRoute(for:))
        for (paneID, pane) in panes {
            if let targetedRoute, paneID == editorArea.focusedPaneID {
                pane.contentCoordinator.contextTrigger(targetedRoute)
            } else {
                pane.contentCoordinator.contextTrigger(editorArea[paneID]?.activeTab.currentEntry == nil ? .placeholder : .back)
            }
        }

        // A command that moves the focus moves the keyboard focus along with it; anything else —
        // a click in the sidebar, a relationship in the Inspector — leaves the keyboard where it is
        // unless it is in the editor area already.
        let movesKeyboardFocus = switch selectionRoute {
        case .focusEditorPane, .newEditorPane, .closeEditorPane, .closeOtherEditorPanes: true
        default: false
        }
        rootViewController.focus(editorArea.focusedPaneID, movingKeyboardFocus: movesKeyboardFocus)
    }

    /// How the pane a route went to shows its object, for the routes that say more than "show the
    /// active tab": `nil` for the others.
    private static func contentRoute(for selectionRoute: SelectionRoute) -> ContentRoute? {
        switch selectionRoute {
        case .open(let object, .newTab, nil, _):
            .root(object)
        case .open(let object, .newTab, let highlightRequest?, _):
            .rootHighlighting(object, highlightRequest)
        case .open(let object, _, nil, _):
            .next(object)
        case .open(let object, _, let highlightRequest?, _):
            .nextHighlighting(object, highlightRequest)
        case .openImage(let imagePath, _):
            .image(imagePath)
        case .selectAtRoot(let object):
            .root(object)
        default:
            nil
        }
    }

    private func makePane(_ paneID: EditorPane.ID) -> Pane {
        let contentCoordinator = ContentCoordinator(documentState: documentState, editorPaneID: paneID)
        addChild(contentCoordinator)
        let viewController = EditorPaneViewController()
        let viewModel = EditorPaneViewModel(paneID: paneID, documentState: documentState, router: self)
        viewController.setupBindings(for: viewModel)
        viewController.setContent(contentCoordinator.rootViewController)
        return Pane(contentCoordinator: contentCoordinator, viewController: viewController)
    }
}
