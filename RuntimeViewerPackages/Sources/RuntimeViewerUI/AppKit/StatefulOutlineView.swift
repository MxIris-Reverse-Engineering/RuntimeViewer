#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import UIFoundation

open class StatefulOutlineView: OutlineView {
    private var savedExpandedItems = Set<AnyHashable>()

    private var needsRestoreState = false

    open func beginFiltering() {
        saveExpansionState()
    }

    open func endFiltering() {
        if !savedExpandedItems.isEmpty {
            needsRestoreState = true
        }
    }

    private func saveExpansionState() {
        savedExpandedItems.removeAll()

        let numberOfRows = numberOfRows

        guard numberOfRows > 0 else { return }

        for i in 0 ..< numberOfRows {
            guard let item = item(atRow: i) else { continue }

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

    open override func reloadData() {
        super.reloadData()
        
        didReloadData()
    }

    private func didReloadData() {
        if needsRestoreState {
            needsRestoreState = false
            DispatchQueue.main.async {
                self.restoreExpansionState()
            }
        }
    }
}

#endif
