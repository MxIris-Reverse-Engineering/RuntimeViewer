#if os(macOS)

import Foundation
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// The routes of the macOS document window, which `MainCoordinator` performs.
@AssociatedValue(.public)
@CaseCheckable(.public)
public enum MainRoute: Routable {
    case main(RuntimeEngine)
    /// The Generation Options popover. Like every route, it carries no view:
    /// `MainCoordinator` takes the toolbar item's button to anchor it at.
    case generationOptions
    case attachToProcess
    /// The MCP status popover, anchored the same way as `generationOptions`.
    case mcpStatus
    case dismiss
    case exportInterfaces
    case exportMultipleImages
    /// Begin the document-window sheet that walks the user through
    /// specializing the supplied generic Swift type. Forwarded by
    /// `InspectorCoordinator` via its delegate.
    case beginSpecializationSheet(RuntimeObject)
    /// Navigate ▸ Reveal in Sidebar Navigator: show the sidebar and have its
    /// object list select and scroll to the object on screen.
    case revealInSidebarNavigator
    /// Edit ▸ Find ▸ Find in Indexed Images…: show the sidebar, switch it to
    /// the Find navigator and focus the search field.
    case find
    /// A cross-reference command ran from outside the Find navigator: show
    /// the sidebar and switch it to the navigator, without moving the focus.
    case showFindResults
    /// View ▸ Show Report Navigator: show the sidebar and switch it to the
    /// Report navigator.
    case reports
    /// View ▸ Reset Editor Sizes: every split of the editor area shares its
    /// extent equally among its panes. Only the views change, so it is not a
    /// `SelectionRoute`.
    case resetEditorSizes
    /// The naming word cloud of the image at this path, in a window of its own:
    /// one per image of the document, brought to the front when it is open.
    case namingWordCloud(imagePath: String)
    /// Load Frameworks on My Mac: the frameworks at these URLs, loaded into an
    /// instance of the framework service of their own, in a window of their
    /// own (proposal `isolated-framework-loading`).
    case openIsolatedFrameworks([URL])
    /// The document's framework loader refused a framework while the window
    /// shows something: its diagnosis in a sheet.
    case frameworkLoadFailure
}

#endif
