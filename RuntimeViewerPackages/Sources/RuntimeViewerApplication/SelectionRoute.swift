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
/// - `push`: record a newly viewed object on the timeline — truncate any
///   forward history, append the entry unless it already sits at the top,
///   and advance the cursor to it (sidebar row click, inspector
///   relationship / specialization child click, content link click).
/// - `pop`: actually remove the topmost entry from the history array
///   and clamp the cursor back into the new bounds. Reserved for callers
///   that need to shrink the history (the toolbar previous button uses
///   `.backward` instead — it only moves the cursor).
/// - `backward`: step the cursor one entry back without mutating the
///   history array (toolbar previous). On an empty tab over a non-empty
///   timeline the first step returns to the cursor entry itself. No-op
///   at index 0 otherwise.
/// - `forward`: step the cursor one entry forward without mutating the
///   history array (toolbar next). No-op at the latest entry.
/// - `jump`: move the cursor straight to an arbitrary history index
///   without mutating the history array (toolbar previous / next
///   long-press history menu). Unlike `pop` it never shrinks the
///   array; unlike `backward` / `forward` it can cross several
///   entries at once. No-op for an out-of-range index or for the
///   index the cursor already sits on — unless the pane shows the
///   placeholder (empty tab), where the same-index jump restores the
///   cursor entry.
/// - `clear`: empty the history but keep `currentImageNode`.
///
/// Tab routes (content-pane tabs — see `DocumentTab`). Tabs and the
/// navigation timeline are independent mechanisms: tab routes never clear
/// the timeline. Reaching a tab's object — like reaching any object — is
/// recorded on the timeline (Xcode-style: back steps through everything
/// viewed, however it was reached), truncating the abandoned forward
/// branch first. The active tab's object is kept in sync with
/// `selectedRuntimeObject` by the router's write-through, so back/forward
/// land in the active tab:
/// - `newTab`: append an empty tab (inheriting the current image) and make
///   it active; the panes show the placeholder while the timeline keeps
///   the cursor on the most recently viewed entry so `.backward` can
///   return to it.
/// - `openInNewTab`: append a tab already showing `object`, make it active
///   (⌘⇧-click / "Open in New Tab"), and record `object` on the timeline.
/// - `switchTab`: make the tab at `index` active and record its object on
///   the timeline (or drop only the forward branch for an empty tab).
///   No-op for the active index.
/// - `closeTab`: remove the tab at `index`. Closing the active tab activates
///   the right neighbour (or the left when there is none) and records its
///   object like `switchTab`. Never removes the last remaining tab — the
///   menu layer turns ⌘W into "close window" then.
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
