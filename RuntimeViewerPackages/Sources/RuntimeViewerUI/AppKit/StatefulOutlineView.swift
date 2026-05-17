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

    // MARK: - Expansion Autosave Configuration
    //
    // Manual replacement for NSOutlineView's `autosaveExpandedItems`. The
    // built-in mechanism only attempts to restore once, at the first moment all
    // of `autosaveName != nil` / `dataSource` responding to
    // `itemForPersistentObject:` / `numberOfRows > 0` are simultaneously true.
    // When the data source is installed after the initial async data load,
    // that single restore window has already passed and the persisted state is
    // silently ignored. This implementation keeps wire-compatible UserDefaults
    // storage (key `"NSOutlineView Items \(name)"`, value `[String]`) while
    // letting the caller control when to restore.

    /// When non-nil, expand/collapse changes are persisted to UserDefaults under
    /// the AppKit-compatible key `"NSOutlineView Items \(expansionAutosaveName)"`.
    open var expansionAutosaveName: String? {
        didSet {
            guard oldValue != expansionAutosaveName else { return }
            updateExpansionAutosaveObservers()
        }
    }

    /// Converts an item into a stable String key. Return nil to skip the item.
    open var persistentObjectForExpansion: ((Any) -> String?)?

    /// Resolves a persisted String key back into an item. Return nil if the item
    /// is not yet available (e.g. background indexing has not finished).
    open var itemForExpansionPersistentObject: ((String) -> Any?)?

    private var expansionAutosaveObservers: [NSObjectProtocol] = []
    private var isApplyingExpansionAutosave = false

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

    // MARK: - Expansion Autosave

    private var expansionAutosaveUserDefaultsKey: String? {
        expansionAutosaveName.map { "NSOutlineView Items \($0)" }
    }

    private func updateExpansionAutosaveObservers() {
        for token in expansionAutosaveObservers {
            NotificationCenter.default.removeObserver(token)
        }
        expansionAutosaveObservers.removeAll()

        guard expansionAutosaveName != nil else { return }

        let center = NotificationCenter.default
        let didExpand = center.addObserver(
            forName: NSOutlineView.itemDidExpandNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.persistExpansionStateIfNeeded()
        }
        let didCollapse = center.addObserver(
            forName: NSOutlineView.itemDidCollapseNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.persistExpansionStateIfNeeded()
        }
        expansionAutosaveObservers = [didExpand, didCollapse]
    }

    private func persistExpansionStateIfNeeded() {
        // Skip during filter-induced expand/collapse churn and during programmatic
        // restore; only user-driven changes in the idle state should be persisted.
        guard !isApplyingExpansionAutosave,
              filteringState == .idle,
              let key = expansionAutosaveUserDefaultsKey,
              let persistentObjectForExpansion else { return }

        var persistentObjects: [String] = []
        let totalRows = numberOfRows
        for rowIndex in 0 ..< totalRows {
            guard let item = item(atRow: rowIndex), isItemExpanded(item) else { continue }
            if let object = persistentObjectForExpansion(item) {
                persistentObjects.append(object)
            }
        }
        UserDefaults.standard.set(persistentObjects, forKey: key)
    }

    /// Reads the persisted expansion state and applies it. Call after data has
    /// loaded and `itemForExpansionPersistentObject` can successfully resolve
    /// items — for example after the background indexing pass completes.
    open func restoreExpansionFromAutosave() {
        guard let key = expansionAutosaveUserDefaultsKey,
              let itemForExpansionPersistentObject,
              let persistentObjects = UserDefaults.standard.array(forKey: key) as? [String] else {
            return
        }

        isApplyingExpansionAutosave = true
        defer { isApplyingExpansionAutosave = false }

        for object in persistentObjects {
            if let item = itemForExpansionPersistentObject(object) {
                expandItem(item)
            }
        }
    }

    deinit {
        for token in expansionAutosaveObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }
}

#endif
