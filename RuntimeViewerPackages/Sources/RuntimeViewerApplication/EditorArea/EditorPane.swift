import Foundation

/// One editor pane: a slot of the editor area with tabs of its own, Xcode's `IDEEditorAreaSplit`.
public struct EditorPane: Hashable, Identifiable, Sendable {
    /// Stable identity of a pane, kept apart from a tab's so that one is never passed for the other.
    public struct ID: Hashable, Sendable {
        private let rawValue: UUID

        init() {
            self.rawValue = UUID()
        }
    }

    public let id: ID

    /// Never empty.
    public internal(set) var tabs: [DocumentTab]

    public internal(set) var activeTabID: DocumentTab.ID

    /// A pane holding `tab` alone, an empty tab unless given one.
    init(id: ID = ID(), tab: DocumentTab = DocumentTab()) {
        self.id = id
        self.tabs = [tab]
        self.activeTabID = tab.id
    }

    public var activeTab: DocumentTab {
        tabs[activeTabIndex]
    }

    public var activeTabIndex: Int {
        tabs.firstIndex { $0.id == activeTabID } ?? 0
    }

    public func index(ofTab tabID: DocumentTab.ID) -> Int? {
        tabs.firstIndex { $0.id == tabID }
    }
}
