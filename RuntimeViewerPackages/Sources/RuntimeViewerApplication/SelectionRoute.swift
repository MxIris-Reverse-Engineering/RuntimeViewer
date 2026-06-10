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
/// - `clear`: empty the history but keep `currentImageNode`.
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
    case clear
}
