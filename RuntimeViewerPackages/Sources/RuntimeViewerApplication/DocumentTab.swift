import Foundation
import RuntimeViewerCore

/// One tab in a document's content pane.
///
/// A tab is a lightweight display slot: it captures the single
/// `RuntimeObject` the user opened in it. Tabs are independent of the
/// document's navigation timeline (`DocumentState.selectionStack`) — they
/// never own a history of their own; the timeline records viewing order
/// across all of them. The *active* tab's `object` mirrors
/// `DocumentState.selectedRuntimeObject` at all times (the router writes
/// navigation through to it, so back/forward land in the active tab); a tab
/// is only ever a frozen snapshot for the *inactive* tabs. `object == nil`
/// is an empty tab that shows the content placeholder.
///
/// `id` is a stable identity that survives `object` changes, so the tab bar
/// (and DifferenceKit) can track a tab across renames / navigation rather
/// than treating every object swap as a new tab.
public struct DocumentTab: Hashable, Identifiable, Sendable {
    public let id: UUID

    public var object: RuntimeObject?

    public init(id: UUID = UUID(), object: RuntimeObject? = nil) {
        self.id = id
        self.object = object
    }

    /// Title shown on the tab. Falls back to a neutral label for an empty tab.
    public var title: String {
        object?.displayName ?? "New Tab"
    }
}
