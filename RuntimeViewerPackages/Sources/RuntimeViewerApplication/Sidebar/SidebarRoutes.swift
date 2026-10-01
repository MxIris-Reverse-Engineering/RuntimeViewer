import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SidebarRoute: Routable {
    case root
    case back
    case selectedNode(RuntimeImageNode)
    case clickedNode(RuntimeImageNode)
    case selectedObject(RuntimeObject)
    /// Select the document's object on screen in the image page's object
    /// list and bring it into view (Navigate ▸ Reveal in Sidebar Navigator).
    /// macOS only.
    case revealSelectedRuntimeObject
    /// Show the Find navigator tab of whichever sidebar level is on screen
    /// and put the keyboard focus in its search field (Edit ▸ Find ▸ Find in
    /// Indexed Images). macOS only.
    case showFind
    /// Show the Report navigator tab of whichever sidebar level is on
    /// screen (View ▸ Show Report Navigator). macOS only.
    case showReports
}

#if os(macOS)
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SidebarRootRoute: Routable {
    case initial
    case directory
    case bookmarks
    /// The Find navigator tab, with the focus moved into its search field.
    case find
    /// The Report navigator tab.
    case reports
}
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum SidebarRuntimeObjectRoute: Routable {
    case initial
    case objects
    case bookmarks
    /// The Find navigator tab, with the focus moved into its search field.
    case find
    /// The Report navigator tab.
    case reports
    /// Switch to the object list and have it reveal the document's object on
    /// screen — see `SidebarRuntimeObjectListViewModel.revealSelectedRuntimeObject()`.
    case revealSelectedRuntimeObject
    /// Open the scope popover anchored at `sender`. The popover view model
    /// reads/writes the same `BehaviorRelay` the sidebar view model exposes,
    /// so user edits land live without an explicit Apply. `availableKinds`
    /// and `availableProperties` are a snapshot of what the current image
    /// actually contains — the popover uses them to skip drawing rows that
    /// would have no effect.
    case scope(
        sender: NSView,
        relay: BehaviorRelay<RuntimeObjectScope>,
        availableKinds: Set<RuntimeObjectKind>,
        availableProperties: RuntimeObject.Properties
    )
}
#else
public typealias SidebarRootRoute = SidebarRoute
public typealias SidebarRuntimeObjectRoute = SidebarRoute
#endif





