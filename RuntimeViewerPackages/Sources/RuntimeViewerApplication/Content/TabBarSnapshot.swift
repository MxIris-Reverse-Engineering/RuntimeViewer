import Foundation
import RuntimeViewerCore

/// One row of the content-pane tab bar, projected from a `DocumentTab`.
///
/// Carries only display-relevant data; icon resolution is left to the view
/// layer (`RuntimeObjectIcon`) so this stays platform-agnostic.
public struct TabBarItem: Hashable, Identifiable, Sendable {
    /// The projected tab's `DocumentTab.id`.
    ///
    /// Carried so the item identifies its *tab* rather than its contents: `title` and `kind` do not,
    /// since two empty tabs — or two tabs opened on the same object — are equal on those alone. The
    /// tab bar matches items across a reload by equality, and a row that cannot be told from its
    /// neighbour is matched to the wrong button.
    public let id: UUID

    public let title: String

    /// Kind of the tab's object, used by the view layer to resolve an icon.
    /// `nil` for an empty tab.
    public let kind: RuntimeObjectKind?

    public init(id: UUID, title: String, kind: RuntimeObjectKind?) {
        self.id = id
        self.title = title
        self.kind = kind
    }
}

/// Immutable projection of `DocumentState.tabs` + `activeTabIndex` for the
/// content-pane tab bar. Mirrors the `NavigationHistorySnapshot` pattern.
public struct TabBarSnapshot: Hashable, Sendable {
    public let items: [TabBarItem]

    /// Index of the active tab in `items`, mirroring
    /// `DocumentState.activeTabIndex`.
    public let activeIndex: Int

    public init(items: [TabBarItem], activeIndex: Int) {
        self.items = items
        self.activeIndex = activeIndex
    }
}
