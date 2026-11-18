#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import RuntimeViewerAppCore

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
