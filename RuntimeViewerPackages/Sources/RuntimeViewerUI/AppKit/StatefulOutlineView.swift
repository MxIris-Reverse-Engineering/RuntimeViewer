#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import UIFoundation

open class StatefulOutlineView: OutlineView {
    private var savedExpandedItems = Set<AnyHashable>()
    private var savedSelectedItem: AnyHashable?

    private enum FilteringState {
        case idle
        case filtering
        case pendingRestore
    }

    private var filteringState: FilteringState = .idle
    private var isReloadingData = false

    open func beginFiltering() {
        guard filteringState == .idle else { return }
        saveExpansionState()
        filteringState = .filtering
    }

    open func endFiltering() {
        guard filteringState == .filtering else { return }

        // Save the selected item while everything is still expanded,
        // so parent(forItem:) can traverse the full ancestor chain
        saveSelectedItemDuringFiltering()

        if savedExpandedItems.isEmpty && savedSelectedItem == nil {
            filteringState = .idle
        } else {
            filteringState = .pendingRestore
            // Fallback: if reloadData is not called by the data driver
            // (e.g. when the root-level array doesn't change),
            // force a reload on the next run loop iteration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.filteringState == .pendingRestore else { return }
                self.reloadData()
            }
        }
    }

    // MARK: - Expansion State

    private func saveExpansionState() {
        savedExpandedItems.removeAll()

        let totalRows = numberOfRows

        guard totalRows > 0 else { return }

        for rowIndex in 0 ..< totalRows {
            guard let item = item(atRow: rowIndex) else { continue }

            if isItemExpanded(item), let hashableItem = item as? AnyHashable {
                savedExpandedItems.insert(hashableItem)
            }
        }
    }

    private func restoreExpansionState() {
        collapseItem(nil, collapseChildren: true)

        var rowIndex = 0

        while rowIndex < numberOfRows {
            guard let item = item(atRow: rowIndex) else {
                rowIndex += 1
                continue
            }

            if let hashableItem = item as? AnyHashable, savedExpandedItems.contains(hashableItem) {
                expandItem(item)
            }

            rowIndex += 1
        }

        savedExpandedItems.removeAll()
    }

    // MARK: - Selection State

    private func saveSelectedItemDuringFiltering() {
        guard selectedRow >= 0, let selected = item(atRow: selectedRow) else {
            savedSelectedItem = nil
            return
        }

        savedSelectedItem = selected as? AnyHashable

        // Add all ancestors to savedExpandedItems so they will be
        // expanded during restore, making the selected item reachable
        var current: Any = selected
        while let parentItem = parent(forItem: current) {
            if let hashableParent = parentItem as? AnyHashable {
                savedExpandedItems.insert(hashableParent)
            }
            current = parentItem
        }
    }

    private func restoreSelectedItem() {
        guard let selectedItem = savedSelectedItem else { return }
        savedSelectedItem = nil

        let row = row(forItem: selectedItem)
        guard row >= 0 else { return }

        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        box.scrollRowToVisible(row, animated: false, scrollPosition: .centeredVertically)
    }

    // MARK: - Reload

    open override func reloadData() {
        guard !isReloadingData else { return }
        isReloadingData = true
        defer { isReloadingData = false }

        super.reloadData()

        switch filteringState {
        case .idle:
            break
        case .filtering:
            expandItem(nil, expandChildren: true)
        case .pendingRestore:
            restoreExpansionState()
            restoreSelectedItem()
            filteringState = .idle
        }
    }
}

#endif
