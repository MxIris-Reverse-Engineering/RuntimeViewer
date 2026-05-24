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
/// - `selectAtRoot`: replace the entire inspection stack with one object
///   (sidebar row click, specialization completion).
/// - `drillInto`: push one object onto the stack (inspector relationship /
///   specialization child click).
/// - `pop`: remove the topmost object (toolbar content back).
/// - `clear`: empty the stack but keep `currentImageNode`.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SelectionRoute: Routable {
    case switchEngine(RuntimeEngine)
    case switchImage(RuntimeImageNode?)
    case selectAtRoot(RuntimeObject)
    case push(RuntimeObject)
    case pop
    case clear
}
