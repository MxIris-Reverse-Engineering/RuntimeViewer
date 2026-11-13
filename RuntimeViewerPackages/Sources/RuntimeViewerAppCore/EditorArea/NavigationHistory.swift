import Foundation
import RuntimeViewerCore

/// What one tab has shown, oldest first, and which entry is on screen: the list the toolbar's
/// back and forward buttons, and their history menus, walk.
///
/// Each tab keeps its own, as each tab of an Xcode editor pane walks only what it has shown
/// (IDEKit 27.2 filters a pane's history by the selected tab's identifier). Equality compares the
/// entries by their objects' identity (`RuntimeObject.==`) and the language they are shown in, so it
/// says nothing about the content an object is shown with.
public struct NavigationHistory: Hashable, Sendable {
    public private(set) var entries: [NavigationEntry]

    /// The entry on screen; `nil` while the tab has shown nothing.
    public private(set) var currentIndex: Int?

    /// A tab that has shown nothing yet.
    public init() {
        self.entries = []
        self.currentIndex = nil
    }

    /// A tab that has shown `entry` and nothing else.
    public init(entry: NavigationEntry) {
        self.entries = [entry]
        self.currentIndex = 0
    }

    public var currentEntry: NavigationEntry? {
        currentIndex.map { entries[$0] }
    }

    public var canGoBackward: Bool {
        guard let currentIndex else { return false }
        return currentIndex > 0
    }

    public var canGoForward: Bool {
        guard let currentIndex else { return false }
        return currentIndex < entries.count - 1
    }

    /// Records `entry` as shown. The entries after the current one are dropped first — a new
    /// branch overwrites the abandoned future, as in a browser. When the last entry is already
    /// `entry` — the same object in the same language, or the same image — only the position moves
    /// there, and an object entry takes on the form just reached (another `displayName`, other
    /// `properties`), so going back and forth restores what was on screen rather than a form the
    /// user has already left.
    mutating func record(_ entry: NavigationEntry) {
        if let currentIndex {
            entries.removeSubrange((currentIndex + 1)...)
        }
        if let lastEntry = entries.last, lastEntry == entry {
            if let lastObject = lastEntry.object, let object = entry.object, !lastObject.hasSameContent(as: object) {
                entries[entries.count - 1] = entry
            }
        } else {
            entries.append(entry)
        }
        currentIndex = entries.count - 1
    }

    mutating func goBackward() {
        guard let currentIndex, currentIndex > 0 else { return }
        self.currentIndex = currentIndex - 1
    }

    mutating func goForward() {
        guard let currentIndex, currentIndex < entries.count - 1 else { return }
        self.currentIndex = currentIndex + 1
    }

    /// Moves to the entry at `index`, without changing the entries. Ignores an index out of range.
    mutating func go(to index: Int) {
        guard entries.indices.contains(index) else { return }
        currentIndex = index
    }

    /// The history becomes `object` alone, shown in its own language — what finishing a
    /// specialization does to the tab.
    mutating func reset(to object: RuntimeObject) {
        entries = [NavigationEntry(object: object)]
        currentIndex = 0
    }
}
