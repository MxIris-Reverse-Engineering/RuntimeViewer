import Foundation
import RuntimeViewerCore

/// One row of the content-pane tab bar, projected from a `DocumentTab`.
///
/// Carries only display-relevant data; icon resolution is left to the view
/// layer (`RuntimeObjectIcon`) so this stays platform-agnostic.
public struct TabBarItem: Hashable, Sendable {
    public let title: String

    /// Kind of the tab's object, used by the view layer to resolve an icon.
    /// `nil` for an empty tab.
    public let kind: RuntimeObjectKind?

    public init(title: String, kind: RuntimeObjectKind?) {
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
