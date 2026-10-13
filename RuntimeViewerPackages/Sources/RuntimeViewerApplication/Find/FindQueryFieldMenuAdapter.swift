#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import AppKitPlus
import RuntimeViewerArchitectures

/// The Find page's query field menu — the one under its magnifying glass — kept out of the view
/// controller so it can be tested.
///
/// Built afresh each time it opens, from the field and the recent queries as they are then, as
/// `-[IDEFindNavigatorQueryParametersController findFieldMenu]` builds Xcode's: Insert Pattern and a
/// separator while the field takes patterns, a dimmed Recent Queries title, the recent queries
/// indented under it, and Clear Recents after a separator — or the title alone when there are
/// none. The field asks its delegate for the menu, which also gives the magnifying glass its menu
/// chevron, so the adapter makes itself the field's delegate.
@MainActor
public final class FindQueryFieldMenuAdapter: NSObject, NSFilterSearchFieldDelegate {
    /// Xcode sets the menu's font to 10 points.
    static let menuFontSize: CGFloat = 10

    private let queryField: NSFindPatternSearchField

    /// The queries the menu lists, most recent first.
    public var recentQueries: [FindQuery] = []

    private let recentQuerySelectedRelay = PublishRelay<FindQuery>()

    private let clearRecentQueriesSelectedRelay = PublishRelay<Void>()

    /// A recent query chosen from the menu.
    public var recentQuerySelected: Signal<FindQuery> {
        recentQuerySelectedRelay.asSignal()
    }

    /// Clear Recents chosen from the menu.
    public var clearRecentQueriesSelected: Signal<Void> {
        clearRecentQueriesSelectedRelay.asSignal()
    }

    public init(queryField: NSFindPatternSearchField) {
        self.queryField = queryField
        super.init()
        queryField.delegate = self
    }

    public func menu(for searchField: NSFilterSearchField) -> NSMenu? {
        makeMenu()
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Find")
        menu.font = .menuFont(ofSize: Self.menuFontSize)
        // Xcode leaves Insert Pattern out while the query takes no patterns, rather than dim it.
        if queryField.allowsPatternInsertion {
            menu.addItem(queryField.insertPatternMenuItem())
            menu.addItem(.separator())
        }
        // No action, so the menu dims it.
        menu.addItem(NSMenuItem(title: "Recent Queries", action: nil, keyEquivalent: ""))
        guard !recentQueries.isEmpty else { return menu }
        for recentQuery in recentQueries {
            let item = NSMenuItem(title: FindRecentQueries.title(for: recentQuery), action: #selector(recentQueryChosen(_:)), keyEquivalent: "")
            item.attributedTitle = FindRecentQueries.attributedTitle(for: recentQuery, font: menu.font)
            item.indentationLevel = 1
            item.representedObject = recentQuery
            item.target = self
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clearItem = NSMenuItem(title: "Clear Recents", action: #selector(clearRecentQueriesChosen(_:)), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)
        return menu
    }

    /// Puts the query's term in the field first, which ends any edit there: the page leaves a field
    /// being edited alone when the query changes, and a recent query is chosen from the field's own
    /// menu, often while it is being edited.
    @objc private func recentQueryChosen(_ sender: NSMenuItem) {
        guard let recentQuery = sender.representedObject as? FindQuery else { return }
        queryField.findPatternComponents = recentQuery.term.components
        recentQuerySelectedRelay.accept(recentQuery)
    }

    @objc private func clearRecentQueriesChosen(_ sender: NSMenuItem) {
        clearRecentQueriesSelectedRelay.accept(())
    }
}

#endif
