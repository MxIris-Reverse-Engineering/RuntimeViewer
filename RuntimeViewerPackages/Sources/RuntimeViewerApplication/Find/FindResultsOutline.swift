#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#endif

import Foundation

/// One update of the Find page's outline: the rows, and what the page does to them once its data
/// source has them.
public struct FindResultsPresentation {
    public let nodes: [FindResultNode]
    /// Rows to show expanded, parents before children; see `FindResultsOutline.nodesToExpand`.
    public let nodesToExpand: [FindResultNode]
    /// The rows the user selected, as nodes of this tree; empty when none of them is shown.
    public let nodesToSelect: [FindResultNode]
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
extension FindResultsPresentation {
    /// Expands `nodesToExpand` and puts the user's selection back on `nodesToSelect`, for an
    /// outline whose data source already holds `nodes`.
    ///
    /// The selection has to be put back by item: a batch only appends types, which the outline's
    /// diff inserts without touching the rows on screen, but a filter change reloads, and AppKit
    /// keeps a reloaded selection by row number. It is only selected, never scrolled to: the user
    /// may have scrolled away from it, and a row that is not on screen has no row view to draw in
    /// the wrong emphasis either. Selecting this way is not a choice the user made, so it reaches
    /// nobody listening to `proposedSelection()`.
    @MainActor
    public func apply(to outlineView: NSOutlineView) {
        for node in nodesToExpand where !outlineView.isItemExpanded(node) {
            outlineView.expandItem(node)
        }
        let selectedRowIndexes = IndexSet(nodesToSelect.map { outlineView.row(forItem: $0) }.filter { $0 >= 0 })
        if outlineView.selectedRowIndexes != selectedRowIndexes {
            outlineView.selectRowIndexes(selectedRowIndexes, byExtendingSelection: false)
        }
    }
}
#endif

/// The Find page's rules for its outline, kept out of the view controller so they can be tested.
enum FindResultsOutline {
    /// The most rows a relationship tree can have, every row expanded, and still be shown fully
    /// expanded. A larger one — every descendant of `NSObject` runs to thousands — opens its first
    /// level only: the types that matched, with what is directly related to them.
    static let largestFullyExpandedRelationshipRowCount = 500

    /// The rows to show expanded, parents before their children: every row with children except
    /// the ones the user collapsed — hits are only useful under an expanded type, as Xcode shows
    /// them — and nothing beneath a collapsed row, which AppKit shows as it last left it once the
    /// user expands the row again. A relationship tree larger than
    /// `largestFullyExpandedRelationshipRowCount` rows opens its first level only.
    static func nodesToExpand(in nodes: [FindResultNode], collapsedIdentifiers: Set<String>, isRelationshipTree: Bool) -> [FindResultNode] {
        let expandsEveryLevel = !isRelationshipTree || rowCount(of: nodes) <= largestFullyExpandedRelationshipRowCount
        var expandableNodes: [FindResultNode] = []
        func collect(_ nodes: [FindResultNode]) {
            for node in nodes where !node.children.isEmpty && !collapsedIdentifiers.contains(node.identifier) {
                expandableNodes.append(node)
                if expandsEveryLevel {
                    collect(node.children)
                }
            }
        }
        collect(nodes)
        return expandableNodes
    }

    /// How many rows `nodes` make with every row expanded.
    static func rowCount(of nodes: [FindResultNode]) -> Int {
        nodes.reduce(0) { count, node in count + 1 + rowCount(of: node.children) }
    }

    /// The rows of the tree whose identifier is among `identifiers`, in tree order.
    static func nodes(in nodes: [FindResultNode], identifiedBy identifiers: Set<String>) -> [FindResultNode] {
        guard !identifiers.isEmpty else { return [] }
        var matchingNodes: [FindResultNode] = []
        func collect(_ nodes: [FindResultNode]) {
            for node in nodes {
                if identifiers.contains(node.identifier) {
                    matchingNodes.append(node)
                }
                collect(node.children)
            }
        }
        collect(nodes)
        return matchingNodes
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
/// How a Find result the user chose is opened, read off the event that chose it.
public enum FindResultActivation {
    /// With ⌥ held the result opens in a new tab — proposal `draft-find-navigator` §4 — otherwise
    /// in the current one.
    public static func opensInNewTab(for triggeringEvent: NSEvent?) -> Bool {
        triggeringEvent?.modifierFlags.contains(.option) == true
    }

    /// Whether `triggeringEvent` is a character typed into the list, which selects a row by its
    /// text one keystroke at a time. A click, an arrow key and a change AppKit reports with no
    /// event are each a choice of their own.
    public static func isTypeSelect(_ triggeringEvent: NSEvent?) -> Bool {
        guard let triggeringEvent, triggeringEvent.type == .keyDown else { return false }
        return !arrowKeyCodes.contains(triggeringEvent.keyCode)
    }

    /// Left, right, down and up.
    private static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]
}
#endif
