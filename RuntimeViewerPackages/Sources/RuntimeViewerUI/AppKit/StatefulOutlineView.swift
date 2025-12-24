#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import UIFoundation

/// An NSOutlineView subclass that can save and restore its expansion state.
/// It's designed to work with any Hashable item type.
///
/// How to use:
/// 1. In Interface Builder, set your NSOutlineView's custom class to "StatefulOutlineView".
/// 2. Before you filter your data source and call reloadData(), call `outlineView.beginFiltering()`.
/// 3. After you apply the filter, call `reloadData()` and then `expandItem(nil, expandChildren: true)`.
/// 4. When you clear the filter, first call `outlineView.endFiltering()`, then restore your data source and call `reloadData()`.
///    The outline view will automatically restore the expansion state when it finishes reloading.
open class StatefulOutlineView: OutlineView {
    // A set to store the hashable representations of the expanded items.
    private var savedExpandedItems = Set<AnyHashable>()

    // A flag to indicate that a restore operation is pending after the next reload.
    private var needsRestoreState = false

    // MARK: - Public API

    /// Call this method *before* you change the data source for filtering.
    /// It saves the current expansion state.
    open func beginFiltering() {
        saveExpansionState()
    }

    /// Call this method *before* you restore the original data source and reload.
    /// It flags that the saved state should be restored after the reload.
    open func endFiltering() {
        // If we have a state to restore, set the flag.
        if !savedExpandedItems.isEmpty {
            needsRestoreState = true
        }
    }

    // MARK: - Internal Logic

    private func saveExpansionState() {
        savedExpandedItems.removeAll()

        // Iterate through all visible rows to find expanded items.
        // This is more direct than traversing the data source.
        let numberOfRows = numberOfRows
        
        guard numberOfRows > 0 else { return }

        for i in 0 ..< numberOfRows {
            guard let item = item(atRow: i) else { continue }

            // If the item is expanded and can be cast to AnyHashable, save it.
            if isItemExpanded(item), let hashableItem = item as? AnyHashable {
                savedExpandedItems.insert(hashableItem)
            }
        }
    }

    private func restoreExpansionState() {
        // Iterate through all rows of the newly reloaded data.
        let numberOfRows = numberOfRows
        
        guard numberOfRows > 0 else { return }
        
        collapseItem(nil, collapseChildren: true)
        
        for i in 0 ..< numberOfRows {
            guard let item = item(atRow: i) else { continue }

            // If the item's hashable representation is in our saved set, expand it.
            if let hashableItem = item as? AnyHashable, savedExpandedItems.contains(hashableItem) {
                expandItem(item)
            }
        }

        // Clear the saved state after a successful restoration.
        savedExpandedItems.removeAll()
    }

    open override func reloadData() {
        super.reloadData()
        didReloadData()
    }
    
    private func didReloadData() {
        // This method is called automatically after reloadData() completes.
        // If a restore was requested, perform it now.
        if needsRestoreState {
            // Reset the flag first to prevent potential loops.
            needsRestoreState = false
            restoreExpansionState()
        }
    }
}

#endif
