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
/// `DocumentState`, and then emitted on `routeSignal` so scene-level
/// subscribers (`MainCoordinator`) can fan out to their child coordinators.
///
/// Each case represents a single, atomic mutation:
/// - `switchEngine`: replace the backing runtime engine and clear any
///   in-flight image / selection state. Triggered from `MainCoordinator`'s
///   `.main` route handler.
/// - `switchImage`: change the currently inspected image, atomically
///   clearing any in-flight drill-down stack (sidebar image click, sidebar
///   back).
/// - `selectAtRoot`: replace the entire inspection history with one
///   object (specialization completion). Resets `selectionIndex` to 0.
/// - `push`: append a new object after the cursor, truncating any
///   forward history first, then advance the cursor to the new entry
///   (sidebar row click, inspector relationship / specialization child
///   click, content link click).
/// - `pop`: actually remove the topmost entry from the history array
///   and clamp the cursor back into the new bounds. Reserved for callers
///   that need to shrink the history (the toolbar previous button uses
///   `.backward` instead — it only moves the cursor).
/// - `backward`: step the cursor one entry back without mutating the
///   history array (toolbar previous). No-op at index 0.
/// - `forward`: step the cursor one entry forward without mutating the
///   history array (toolbar next). No-op at the latest entry.
/// - `jump`: move the cursor straight to an arbitrary history index
///   without mutating the history array (toolbar previous / next
///   long-press history menu). Unlike `pop` it never shrinks the
///   array; unlike `backward` / `forward` it can cross several
///   entries at once. No-op for an out-of-range index or for the
///   index the cursor already sits on.
/// - `clear`: empty the history but keep `currentImageNode`.
///
/// Tab routes (content-pane tabs — see `DocumentTab`). Every tab shares the
/// one document-level navigation history; switching tabs rebinds the shared
/// history to the target tab's object. The active tab's object is kept in
/// sync with `selectedRuntimeObject` by the router after every history
/// mutation, so these routes only handle tab *lifecycle*:
/// - `newTab`: append an empty tab (inheriting the current image) and make it
///   active; the shared history is cleared so the panes show the placeholder.
/// - `openInNewTab`: append a tab already showing `object` and make it active
///   (⌘⇧-click / "Open in New Tab"); the shared history is reset to `[object]`.
/// - `switchTab`: make the tab at `index` active and rebind the shared history
///   to its object (or clear it for an empty tab). No-op for the active index.
/// - `closeTab`: remove the tab at `index`. Closing the active tab activates
///   the right neighbour (or the left when there is none). Never removes the
///   last remaining tab — the menu layer turns ⌘W into "close window" then.
/// - `moveTab`: reorder a tab (drag), keeping the active tab active.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SelectionRoute: Routable {
    case switchEngine(RuntimeEngine)
    case switchImage(RuntimeImageNode?)
    case selectAtRoot(RuntimeObject)
    case push(RuntimeObject)
    case pop
    case backward
    case forward
    case jump(toIndex: Int)
    case clear
    case newTab
    case openInNewTab(RuntimeObject)
    case switchTab(index: Int)
    case closeTab(index: Int)
    case moveTab(from: Int, to: Int)
}
