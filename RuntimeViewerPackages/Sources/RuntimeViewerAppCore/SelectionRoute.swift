import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// Document-scoped navigation routes.
///
/// `SelectionRoute` is the shared vocabulary that lets sidebar / content /
/// inspector view models express what the user wants to happen without
/// knowing about each other or about `MainCoordinator`. Routes are
/// triggered on `DocumentState.selectionRouter`, applied atomically to
/// `DocumentState` — its `editorArea` above all — and then emitted on
/// `routeSignal` so scene-level subscribers (`MainCoordinator`) can fan out
/// to their child coordinators.
///
/// The editor area holds one or more editor panes, each with tabs of its
/// own, each tab with its own history (proposal `editor-panes`). Every
/// route that does not name a tab or a pane acts on the focused pane and its
/// active tab, the way Xcode's commands act on the last active editor.
///
/// - `switchEngine`: replace the backing runtime engine and start the editor
///   area over with one empty pane. Triggered from `MainCoordinator`'s `.main`
///   route handler only.
/// - `switchImage`: change the image the sidebar lists. Panes, tabs and
///   histories stay: an object of another image stays open where it is.
/// - `open`: show an object in the focused tab, a new tab or the next pane,
///   optionally with a place in its interface to reveal (a Find hit), and in a
///   language other than its own — `.swift` for an Objective-C object shown as
///   Swift imports it (Generated Interface).
/// - `openImage`: show an image, by the path its image tree node gives, before
///   any of its objects — an image chosen in an editor pane's jump bar
///   (proposal `editor-jump-bar`). A step of the tab's history like `open`;
///   the sidebar does not move.
/// - `selectAtRoot`: the focused tab's history becomes one object
///   (specialization completion).
/// - `backward` / `forward` / `jump`: move along the focused tab's history
///   without changing it; no-ops at either end and for the entry on screen.
/// - `newTab`: an empty tab at the end of the focused pane.
/// - `switchTab` / `closeTab` / `moveTab`: act on the named tab, in whichever
///   pane holds it; `switchTab` also focuses that pane, and closing a pane's
///   last tab closes the pane while there is another.
/// - `newEditorPane` / `closeEditorPane` / `closeOtherEditorPanes` /
///   `focusEditorPane` / `changeEditorOrientation`: arrange the panes by
///   Xcode's rules (`EditorLayout`).
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SelectionRoute: Routable {
    case switchEngine(RuntimeEngine)
    case switchImage(RuntimeImageNode?)
    case open(RuntimeObject, in: Destination, highlighting: ContentHighlightRequest? = nil, interfaceLanguage: RuntimeInterfaceLanguage? = nil)
    case openImage(String, in: Destination)
    case selectAtRoot(RuntimeObject)
    case backward
    case forward
    case jump(toIndex: Int)
    case newTab
    case switchTab(DocumentTab.ID)
    case closeTab(DocumentTab.ID)
    case moveTab(DocumentTab.ID, toIndex: Int)
    case newEditorPane(EditorPanePlacement)
    case closeEditorPane(EditorPane.ID)
    case closeOtherEditorPanes
    case focusEditorPane(EditorPane.ID)
    case changeEditorOrientation

    /// Where `open` shows an object — the three targets Xcode offers by default for a click, an
    /// ⌥-click and an ⇧⌥-click.
    public enum Destination: Hashable, Sendable {
        /// The focused pane's active tab, recorded on its history.
        case focusedTab

        /// A new tab at the end of the focused pane.
        case newTab

        /// The pane after the focused one, in layout order; while the focused pane is the only
        /// one, a pane made after it along the root.
        case nextEditorPane
    }
}
