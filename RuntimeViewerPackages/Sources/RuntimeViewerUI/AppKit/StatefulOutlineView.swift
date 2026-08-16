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

    /// Whether a coalesced autosave flush is already queued on the main
    /// queue. Expand/collapse notifications arrive once per item — an
    /// option-click "expand all" posts one per descendant — and each used
    /// to trigger a full row walk plus a `UserDefaults` write, turning
    /// the burst into O(rows²). One queued flush per burst keeps the
    /// total cost at a single O(rows) walk.
    private var isExpansionPersistScheduled = false

    /// Monotonic counter of structural data changes, bumped by every
    /// `NSOutlineView` entry point that can replace or reshape the item
    /// tree. A queued persist samples it at schedule time and refuses to
    /// flush against a different value.
    ///
    /// Without that check the coalescing window is long enough for a tree
    /// rebuild to land between the expand and the walk. The rebuilt tree
    /// comes back fully collapsed — the sidebar maps every `$nodes`
    /// emission through a fresh cell view model and its `Differentiable`
    /// conformance resolves `differenceIdentifier` to `self`, so every row
    /// is a new item — and the walk then wrote an empty array over the
    /// user's saved state. `restoreExpansionFromAutosave()` runs once per
    /// document, so nothing recovers it.
    ///
    /// Expand / collapse notifications are delivered synchronously
    /// (`NotificationCenter` runs the block inline when the observer queue
    /// is the posting queue), so the sample always describes the tree the
    /// user acted on.
    private var dataStructureVersion = 0

    /// `dataStructureVersion` sampled when the pending persist was
    /// scheduled; nil when no flush is queued.
    private var scheduledExpansionPersistStructureVersion: Int?

    /// Number of persist walks actually performed. Regression seam for
    /// the coalescing behavior (see `StatefulOutlineViewAutosaveTests`).
    package private(set) var expansionAutosavePersistCount = 0

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

        // Scroll before selecting. A row view is materialized as its row is
        // scrolled into view, and the emphasized (accent-colored) selection
        // style is applied on a pass after that — so selecting first draws the
        // row once with the inactive grey highlight and flips it on the next
        // frame. Forcing the layout closes the gap the raw clip-view scroll
        // leaves behind, so the row view exists when the selection lands.
        if !box.visibleRowIndexes.contains(row) {
            box.scrollRowToVisible(row, animated: false, scrollPosition: .centeredVertically)
            layoutSubtreeIfNeeded()
        }
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    // MARK: - Reload

    open override func reloadData() {
        guard !isReloadingData else { return }
        isReloadingData = true
        defer { isReloadingData = false }

        dataStructureVersion &+= 1
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

    // The incremental counterparts of `reloadData()`. A diffing adapter
    // reaches for these whenever it can — RxAppKit only falls back to
    // `reloadData()` when the changeset carries `elementUpdated` entries or
    // exceeds its animation threshold — so hooking the full-reload path
    // alone would miss the common tree replacement.

    open override func insertItems(
        at indexes: IndexSet,
        inParent parent: Any?,
        withAnimation animationOptions: NSTableView.AnimationOptions = []
    ) {
        dataStructureVersion &+= 1
        super.insertItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    open override func removeItems(
        at indexes: IndexSet,
        inParent parent: Any?,
        withAnimation animationOptions: NSTableView.AnimationOptions = []
    ) {
        dataStructureVersion &+= 1
        super.removeItems(at: indexes, inParent: parent, withAnimation: animationOptions)
    }

    open override func moveItem(at fromIndex: Int, inParent oldParent: Any?, to toIndex: Int, inParent newParent: Any?) {
        dataStructureVersion &+= 1
        super.moveItem(at: fromIndex, inParent: oldParent, to: toIndex, inParent: newParent)
    }

    open override func reloadItem(_ item: Any?, reloadChildren: Bool) {
        // `reloadChildren: false` only re-reads one row's display values;
        // the subtree, and therefore the expansion state, is untouched.
        if reloadChildren {
            dataStructureVersion &+= 1
        }
        super.reloadItem(item, reloadChildren: reloadChildren)
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
            self?.scheduleExpansionPersist()
        }
        let didCollapse = center.addObserver(
            forName: NSOutlineView.itemDidCollapseNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleExpansionPersist()
        }
        expansionAutosaveObservers = [didExpand, didCollapse]
    }

    /// Coalesces a burst of expand/collapse notifications into one
    /// persist walk on the next main-queue turn. The full precondition
    /// set re-runs at flush time because the state can change within the
    /// coalescing window (a filter starting, the autosave name clearing).
    /// Best-effort by design: a flush pending when the view deallocates
    /// is dropped, losing at most the burst from the final runloop turn.
    private func scheduleExpansionPersist() {
        guard !isApplyingExpansionAutosave,
              filteringState == .idle,
              expansionAutosaveUserDefaultsKey != nil,
              persistentObjectForExpansion != nil,
              !isExpansionPersistScheduled else { return }
        isExpansionPersistScheduled = true
        scheduledExpansionPersistStructureVersion = dataStructureVersion
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isExpansionPersistScheduled = false
            defer { self.scheduledExpansionPersistStructureVersion = nil }
            self.persistExpansionStateIfNeeded()
        }
    }

    private func persistExpansionStateIfNeeded() {
        // Skip during filter-induced expand/collapse churn and during programmatic
        // restore; only user-driven changes in the idle state should be persisted.
        //
        // The structure version must still match the one sampled at schedule
        // time: the walk below describes whatever tree is installed *now*,
        // and persisting a tree the user never acted on destroys their saved
        // state. Note the guard is on the data changing, not on the walk
        // coming back empty — collapsing every row is a legitimate way to
        // persist an empty set.
        guard !isApplyingExpansionAutosave,
              filteringState == .idle,
              scheduledExpansionPersistStructureVersion == dataStructureVersion,
              let key = expansionAutosaveUserDefaultsKey,
              let persistentObjectForExpansion else { return }

        expansionAutosavePersistCount += 1
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
