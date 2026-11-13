import Foundation

/// How the editor area arranges its panes, by Xcode's rules: a root split whose items are panes or
/// child splits running across it. A child split holds panes only, and at least two of them, so an
/// arrangement never goes deeper than the two levels Xcode allows — the type cannot express a third.
///
/// The rules are Xcode 27.2's (IDEKit 27B52), recorded with their addresses in the RE notes for that
/// build ("Editor panes"): a child is only ever made by the root wrapping one of its panes
/// (`-[IDEEditorMultipleSplit _addOppositeLayoutEditorSplitAtIndexInNewChildMultipleSplit:client:]`
/// asserts it has no parent), and a child left with one pane collapses back into the root.
public struct EditorLayout: Hashable, Sendable {
    public enum Item: Hashable, Sendable {
        case pane(EditorPane.ID)

        /// Panes arranged in the root's `orientation.opposite`; never fewer than two.
        case split([EditorPane.ID])

        public var paneIDs: [EditorPane.ID] {
            switch self {
            case .pane(let paneID): [paneID]
            case .split(let paneIDs): paneIDs
            }
        }
    }

    /// Which splits need their panes equalized after a change, see `splitsToEqualize(comparedWith:)`.
    public enum EqualizedSplits: Hashable, Sendable {
        case none
        /// The root and every child split.
        case all
        /// The child splits at these indices of `items`.
        case children(IndexSet)
    }

    public private(set) var orientation: EditorPaneOrientation

    public private(set) var items: [Item]

    /// One pane, side by side — how a window starts (`-[IDEEditorArea loadView]` sets the root to
    /// side by side).
    public init(pane paneID: EditorPane.ID) {
        self.orientation = .sideBySide
        self.items = [.pane(paneID)]
    }

    /// Every pane, depth first: left to right and top to bottom, the order Move Focus to Next
    /// Editor Pane walks.
    public var paneIDs: [EditorPane.ID] {
        items.flatMap(\.paneIDs)
    }

    public func contains(_ paneID: EditorPane.ID) -> Bool {
        location(of: paneID) != nil
    }

    /// The pane after `paneID` in `paneIDs`, wrapping around to the first.
    public func paneID(after paneID: EditorPane.ID) -> EditorPane.ID {
        let paneIDs = paneIDs
        guard let index = paneIDs.firstIndex(of: paneID) else { return paneID }
        return paneIDs[(index + 1) % paneIDs.count]
    }

    /// The pane before `paneID` in `paneIDs`, wrapping around to the last.
    public func paneID(before paneID: EditorPane.ID) -> EditorPane.ID {
        let paneIDs = paneIDs
        guard let index = paneIDs.firstIndex(of: paneID) else { return paneID }
        return paneIDs[(index + paneIDs.count - 1) % paneIDs.count]
    }

    /// The pane a close leaves the focus to when `paneID` goes: its next sibling in the split that
    /// holds it, else the one before (`-[IDEEditorArea _removeEditorAreaSplit:client:]`). A sibling
    /// that is a child split hands it to its first pane, as Xcode's `takeFocus` on a split does.
    /// `nil` for the only pane.
    public func paneID(succeeding paneID: EditorPane.ID) -> EditorPane.ID? {
        switch location(of: paneID) {
        case .none:
            return nil
        case .root(let itemIndex):
            if itemIndex + 1 < items.count {
                return items[itemIndex + 1].paneIDs.first
            }
            if itemIndex > 0 {
                return items[itemIndex - 1].paneIDs.first
            }
            return nil
        case .child(let itemIndex, let paneIndex):
            let siblings = items[itemIndex].paneIDs
            return paneIndex + 1 < siblings.count ? siblings[paneIndex + 1] : siblings[paneIndex - 1]
        }
    }

    /// New Editor Pane On Right / Below, made from `sourcePaneID`: the four cases of
    /// `-[IDEEditorAreaSplit _newEditorAreaSplitWithLayout:sender:]` (0x1085BC).
    ///
    /// - In the direction of the split that holds the source: right after it, in that split.
    /// - Across it, while the source is the only pane: the root turns first, then the same.
    /// - Across it, with the source in the root: the source is wrapped in a new child split,
    ///   followed by the new pane.
    /// - Across it, with the source in a child split: into the root, after the whole child split.
    mutating func insert(_ newPaneID: EditorPane.ID, placed placement: EditorPanePlacement, relativeTo sourcePaneID: EditorPane.ID) {
        let requestedOrientation = placement.orientation
        switch location(of: sourcePaneID) {
        case .none:
            return
        case .root(let itemIndex):
            if requestedOrientation == orientation {
                items.insert(.pane(newPaneID), at: itemIndex + 1)
            } else if items.count == 1 {
                orientation = orientation.opposite
                items.insert(.pane(newPaneID), at: itemIndex + 1)
            } else {
                items[itemIndex] = .split([sourcePaneID, newPaneID])
            }
        case .child(let itemIndex, let paneIndex):
            if requestedOrientation == orientation.opposite {
                var paneIDs = items[itemIndex].paneIDs
                paneIDs.insert(newPaneID, at: paneIndex + 1)
                items[itemIndex] = .split(paneIDs)
            } else {
                items.insert(.pane(newPaneID), at: itemIndex + 1)
            }
        }
    }

    /// Takes `paneID` out. A child split left with one pane gives way to that pane, in the child
    /// split's place. The only pane is never removed.
    mutating func remove(_ paneID: EditorPane.ID) {
        switch location(of: paneID) {
        case .none:
            return
        case .root(let itemIndex):
            guard paneIDs.count > 1 else { return }
            items.remove(at: itemIndex)
        case .child(let itemIndex, let paneIndex):
            var paneIDs = items[itemIndex].paneIDs
            paneIDs.remove(at: paneIndex)
            items[itemIndex] = paneIDs.count == 1 ? .pane(paneIDs[0]) : .split(paneIDs)
        }
    }

    /// Change Editor Orientation: every split turns across and the arrangement stays — a
    /// transposition (`-[IDEEditorArea toggleEditorOrientation:]`, 0x1001DC, which keeps the sizes).
    mutating func changeOrientation() {
        orientation = orientation.opposite
    }

    /// Which splits need their panes equalized after the change from `previousLayout`, the way
    /// Xcode equalizes after adding a pane (`-[IDEEditorMultipleSplit resetEditorSizes]`, 0x13C6BC):
    /// all of them when the root's own items changed — a pane added to or taken from the root, a
    /// pane wrapped into a child split or a child split collapsed — otherwise each child split whose
    /// panes changed. Turning the orientation keeps the sizes.
    public func splitsToEqualize(comparedWith previousLayout: EditorLayout) -> EqualizedSplits {
        guard rootSlots != previousLayout.rootSlots else {
            var changedChildren = IndexSet()
            for (itemIndex, item) in items.enumerated() where item != previousLayout.items[itemIndex] {
                changedChildren.insert(itemIndex)
            }
            return changedChildren.isEmpty ? .none : .children(changedChildren)
        }
        return .all
    }

    // MARK: - Locating

    private enum Location: Equatable {
        case root(itemIndex: Int)
        case child(itemIndex: Int, paneIndex: Int)
    }

    private func location(of paneID: EditorPane.ID) -> Location? {
        for (itemIndex, item) in items.enumerated() {
            switch item {
            case .pane(let rootPaneID) where rootPaneID == paneID:
                return .root(itemIndex: itemIndex)
            case .split(let paneIDs):
                if let paneIndex = paneIDs.firstIndex(of: paneID) {
                    return .child(itemIndex: itemIndex, paneIndex: paneIndex)
                }
            default:
                continue
            }
        }
        return nil
    }

    /// The root's items with the panes inside child splits left out: what tells a change of the
    /// root's own arrangement from a change inside one of its child splits.
    private enum RootSlot: Hashable {
        case pane(EditorPane.ID)
        case split
    }

    private var rootSlots: [RootSlot] {
        items.map { item in
            switch item {
            case .pane(let paneID): .pane(paneID)
            case .split: .split
            }
        }
    }
}
