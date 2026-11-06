import Foundation
import RuntimeViewerCore

/// One tab of an editor pane's tab bar, projected from a `DocumentTab`.
///
/// Carries only display-relevant data; icon resolution is left to the view
/// layer (`RuntimeObjectIcon`) so this stays platform-agnostic.
public struct TabBarItem: Hashable, Identifiable, Sendable {
    /// The projected tab's `DocumentTab.id`.
    ///
    /// Carried so the item identifies its *tab* rather than its contents: `title` and `kind` do not,
    /// since two empty tabs — or two tabs opened on the same object — are equal on those alone. The
    /// tab bar matches items across a reload by equality, and a row that cannot be told from its
    /// neighbour is matched to the wrong button. It is also what a click on the tab reports, so the
    /// route names the tab rather than a position another route may have moved.
    public let id: DocumentTab.ID

    public let title: String

    /// Kind of the tab's object, used by the view layer to resolve an icon.
    /// `nil` for an empty tab.
    public let kind: RuntimeObjectKind?

    public init(id: DocumentTab.ID, title: String, kind: RuntimeObjectKind?) {
        self.id = id
        self.title = title
        self.kind = kind
    }

    /// The row a tab bar shows for `tab`.
    public init(tab: DocumentTab) {
        self.init(id: tab.id, title: tab.title, kind: tab.object?.kind)
    }
}

/// Immutable projection of an editor pane's `tabs` and active tab for its tab bar. Mirrors the
/// `NavigationHistorySnapshot` pattern.
public struct TabBarSnapshot: Hashable, Sendable {
    public let items: [TabBarItem]

    /// Index of the active tab in `items`.
    public let activeIndex: Int

    public init(items: [TabBarItem], activeIndex: Int) {
        self.items = items
        self.activeIndex = activeIndex
    }

    /// What the tab bar of `pane` shows.
    public init(pane: EditorPane) {
        self.init(items: pane.tabs.map(TabBarItem.init(tab:)), activeIndex: pane.activeTabIndex)
    }
}
