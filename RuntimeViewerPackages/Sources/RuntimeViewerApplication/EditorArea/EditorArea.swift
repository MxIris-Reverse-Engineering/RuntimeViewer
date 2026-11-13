import Foundation
import RuntimeViewerCore

/// Everything the editor area shows, as one value: its panes with their tabs and histories, how the
/// panes are arranged, and which one has the focus.
///
/// One value, published as one `DocumentState` property, so that no reader ever sees a layout
/// naming a pane that is not there yet, or a focus on a pane that has gone. Only `SelectionRouter`
/// changes it, through the methods below, each of which keeps three things true: there is at least
/// one pane, every pane has at least one tab, and the focused pane is one of the panes.
///
/// Equality compares the objects in the histories by identity (`RuntimeObject.==`), so two areas
/// showing one type in two forms are equal: a reader that shows titles or other fields compares what
/// it shows, such as a `TabBarSnapshot`, not the area.
public struct EditorArea: Hashable, Sendable {
    public private(set) var layout: EditorLayout

    public internal(set) var panes: [EditorPane.ID: EditorPane]

    public private(set) var focusedPaneID: EditorPane.ID

    /// What ⌘W closes, see `closeTarget`.
    public enum CloseTarget: Hashable, Sendable {
        case tab(DocumentTab.ID)
        case pane(EditorPane.ID)
        case window
    }

    /// One pane holding one empty tab: a new window, and a document starting over on an engine.
    public init() {
        let pane = EditorPane()
        self.layout = EditorLayout(pane: pane.id)
        self.panes = [pane.id: pane]
        self.focusedPaneID = pane.id
    }

    public var focusedPane: EditorPane {
        guard let focusedPane = panes[focusedPaneID] else {
            preconditionFailure("The focused editor pane is not one of the editor area's panes")
        }
        return focusedPane
    }

    /// The panes in `layout.paneIDs` order: left to right, top to bottom.
    public var orderedPanes: [EditorPane] {
        layout.paneIDs.compactMap { panes[$0] }
    }

    public subscript(paneID: EditorPane.ID) -> EditorPane? {
        panes[paneID]
    }

    public func paneID(containing tabID: DocumentTab.ID) -> EditorPane.ID? {
        panes.values.first { $0.index(ofTab: tabID) != nil }?.id
    }

    /// Whether no tab of any pane has shown anything.
    public var hasShownNothing: Bool {
        panes.values.allSatisfy { pane in
            pane.tabs.allSatisfy { $0.history.entries.isEmpty }
        }
    }

    /// What ⌘W closes: the focused pane's active tab while the pane has another, else the focused
    /// pane while there is another, else the window — the order of Xcode's Close Tab, Editor Pane,
    /// Window Tab, or Window.
    public var closeTarget: CloseTarget {
        let focusedPane = focusedPane
        if focusedPane.tabs.count > 1 {
            return .tab(focusedPane.activeTabID)
        }
        if panes.count > 1 {
            return .pane(focusedPaneID)
        }
        return .window
    }

    // MARK: - Opening

    /// Shows `object` where `destination` says, in `interfaceLanguage` (`nil` for its own), and
    /// returns the pane it is shown in, which has the focus afterwards.
    @discardableResult
    mutating func open(_ object: RuntimeObject, in destination: SelectionRoute.Destination, interfaceLanguage: RuntimeInterfaceLanguage? = nil) -> EditorPane.ID {
        open(NavigationEntry(object: object, interfaceLanguage: interfaceLanguage), in: destination)
    }

    /// Shows `entry` — an object, or an image before any of its objects — where `destination`
    /// says, and returns the pane it is shown in, which has the focus afterwards.
    ///
    /// The next pane is the one after the focused pane in layout order. While the focused pane is
    /// the only one, a pane is made after it along the root, as Xcode's ⇧⌥-click does, and the
    /// entry is all that pane has shown.
    @discardableResult
    mutating func open(_ entry: NavigationEntry, in destination: SelectionRoute.Destination) -> EditorPane.ID {
        switch destination {
        case .focusedTab:
            updateActiveTab(ofPane: focusedPaneID) { $0.history.record(entry) }
        case .newTab:
            addTab(DocumentTab(history: NavigationHistory(entry: entry)), toPane: focusedPaneID)
        case .nextEditorPane:
            if panes.count == 1 {
                let placement: EditorPanePlacement = layout.orientation == .sideBySide ? .onRight : .below
                insertPane(EditorPane(tab: DocumentTab(history: NavigationHistory(entry: entry))), placed: placement)
            } else {
                focusedPaneID = layout.paneID(after: focusedPaneID)
                updateActiveTab(ofPane: focusedPaneID) { $0.history.record(entry) }
            }
        }
        return focusedPaneID
    }

    // MARK: - History of the focused tab

    mutating func goBackward() -> Bool {
        guard focusedPane.activeTab.history.canGoBackward else { return false }
        updateActiveTab(ofPane: focusedPaneID) { $0.history.goBackward() }
        return true
    }

    mutating func goForward() -> Bool {
        guard focusedPane.activeTab.history.canGoForward else { return false }
        updateActiveTab(ofPane: focusedPaneID) { $0.history.goForward() }
        return true
    }

    mutating func goToHistoryEntry(at index: Int) -> Bool {
        let history = focusedPane.activeTab.history
        guard history.entries.indices.contains(index), index != history.currentIndex else { return false }
        updateActiveTab(ofPane: focusedPaneID) { $0.history.go(to: index) }
        return true
    }

    /// The focused tab's history becomes `object` alone.
    mutating func resetFocusedTab(to object: RuntimeObject) {
        updateActiveTab(ofPane: focusedPaneID) { $0.history.reset(to: object) }
    }

    // MARK: - Tabs

    /// New Tab: an empty tab at the end of the focused pane, made active.
    mutating func addEmptyTab() {
        addTab(DocumentTab(), toPane: focusedPaneID)
    }

    /// Makes `tabID` the active tab of its pane and that pane the focused one, as a click on a tab
    /// does. `false` when both already were.
    mutating func selectTab(_ tabID: DocumentTab.ID) -> Bool {
        guard let paneID = paneID(containing: tabID), let pane = panes[paneID] else { return false }
        guard pane.activeTabID != tabID || focusedPaneID != paneID else { return false }
        panes[paneID]?.activeTabID = tabID
        focusedPaneID = paneID
        return true
    }

    /// Closes `tabID`. Closing the active tab activates the one to its right, or to its left when it
    /// was the last. A pane's last tab closes the pane while there is another; the only tab of the
    /// only pane stays, and `false` says nothing changed.
    mutating func closeTab(_ tabID: DocumentTab.ID) -> Bool {
        guard let paneID = paneID(containing: tabID), var pane = panes[paneID], let tabIndex = pane.index(ofTab: tabID) else { return false }
        guard pane.tabs.count > 1 else { return closePane(paneID) }
        let wasActive = pane.activeTabID == tabID
        pane.tabs.remove(at: tabIndex)
        if wasActive {
            pane.activeTabID = pane.tabs[min(tabIndex, pane.tabs.count - 1)].id
        }
        panes[paneID] = pane
        return true
    }

    /// Moves `tabID` to `destinationIndex` within its pane.
    mutating func moveTab(_ tabID: DocumentTab.ID, to destinationIndex: Int) -> Bool {
        guard let paneID = paneID(containing: tabID), var pane = panes[paneID], let tabIndex = pane.index(ofTab: tabID),
              pane.tabs.indices.contains(destinationIndex), tabIndex != destinationIndex
        else { return false }
        let tab = pane.tabs.remove(at: tabIndex)
        pane.tabs.insert(tab, at: destinationIndex)
        panes[paneID] = pane
        return true
    }

    // MARK: - Panes

    /// New Editor Pane On Right / Below: a pane placed by Xcode's rules beside the focused one,
    /// showing what the focused pane's active tab shows — that one entry, without its back and
    /// forward, as Xcode opens only the source tab's current item in a new pane — and taking the focus.
    mutating func addPane(placed placement: EditorPanePlacement) {
        let history = focusedPane.activeTab.currentEntry.map(NavigationHistory.init(entry:)) ?? NavigationHistory()
        insertPane(EditorPane(tab: DocumentTab(history: history)), placed: placement)
    }

    /// Closes `paneID`; when it had the focus, the focus goes to its sibling (`EditorLayout.paneID(succeeding:)`).
    /// The only pane stays, and `false` says nothing changed.
    mutating func closePane(_ paneID: EditorPane.ID) -> Bool {
        guard panes.count > 1, panes[paneID] != nil else { return false }
        let succeedingPaneID = layout.paneID(succeeding: paneID)
        layout.remove(paneID)
        panes[paneID] = nil
        if focusedPaneID == paneID, let succeedingPaneID {
            focusedPaneID = succeedingPaneID
        }
        return true
    }

    /// Close Other Editor Panes: only the focused pane stays, and the layout keeps its orientation.
    mutating func closeOtherPanes() -> Bool {
        guard panes.count > 1 else { return false }
        for paneID in layout.paneIDs where paneID != focusedPaneID {
            layout.remove(paneID)
            panes[paneID] = nil
        }
        return true
    }

    /// Gives `paneID` the focus. `false` when it already has it, or is not a pane of this area.
    mutating func focus(_ paneID: EditorPane.ID) -> Bool {
        guard paneID != focusedPaneID, panes[paneID] != nil else { return false }
        focusedPaneID = paneID
        return true
    }

    /// Change Editor Orientation, see `EditorLayout.changeOrientation()`.
    mutating func changeOrientation() {
        layout.changeOrientation()
    }

    // MARK: - Helpers

    private mutating func insertPane(_ pane: EditorPane, placed placement: EditorPanePlacement) {
        panes[pane.id] = pane
        layout.insert(pane.id, placed: placement, relativeTo: focusedPaneID)
        focusedPaneID = pane.id
    }

    private mutating func addTab(_ tab: DocumentTab, toPane paneID: EditorPane.ID) {
        panes[paneID]?.tabs.append(tab)
        panes[paneID]?.activeTabID = tab.id
    }

    private mutating func updateActiveTab(ofPane paneID: EditorPane.ID, _ update: (inout DocumentTab) -> Void) {
        guard var pane = panes[paneID] else { return }
        update(&pane.tabs[pane.activeTabIndex])
        panes[paneID] = pane
    }
}
