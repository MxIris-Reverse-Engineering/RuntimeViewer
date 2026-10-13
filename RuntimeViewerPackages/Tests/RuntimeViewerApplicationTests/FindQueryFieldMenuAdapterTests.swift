import AppKit
import AppKitPlus
import Foundation
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// `FindQueryFieldMenuAdapter`: the Find page's query field menu as
/// `-[IDEFindNavigatorQueryParametersController findFieldMenu]` builds Xcode's — Insert Pattern
/// while the query takes patterns, then the recent queries under a dimmed title, then Clear
/// Recents. The field is a real one, off screen. An item is chosen by sending its action to its
/// target with the item as the sender, as AppKit does: a menu's tracking loop cannot run in a test,
/// and `performActionForItem(at:)` sends through `NSApp`, which a `swift test` process does not have.
@Suite("FindQueryFieldMenuAdapter")
@MainActor
struct FindQueryFieldMenuAdapterTests {
    private static let recentQueries = [
        FindQuery(text: "NSView", isCaseSensitive: true),
        FindQuery(mode: .members, text: "frame", memberMatchStyle: .matchingWord, scope: .currentImage),
    ]

    private func makeAdapter() -> (NSFindPatternSearchField, FindQueryFieldMenuAdapter) {
        let queryField = NSFindPatternSearchField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        let adapter = FindQueryFieldMenuAdapter(queryField: queryField)
        return (queryField, adapter)
    }

    private func titles(of menu: NSMenu) -> [String] {
        menu.items.map { $0.isSeparatorItem ? "-" : $0.title }
    }

    private func choose(_ item: NSMenuItem) throws {
        let target = try #require(item.target as? NSObject)
        let action = try #require(item.action)
        _ = target.perform(action, with: item)
    }

    @Test("the adapter answers the field's menu, which gives the magnifying glass its menu")
    func answersTheFieldsMenu() {
        let (queryField, adapter) = makeAdapter()
        defer { withExtendedLifetime(adapter) {} }

        #expect((queryField.delegate as AnyObject?) === adapter)
        #expect(adapter.menu(for: queryField) != nil)
    }

    @Test("with no recent queries the menu is Insert Pattern and the dimmed Recent Queries title, in Xcode's 10-point font")
    func menuWithoutRecentQueries() throws {
        let (queryField, adapter) = makeAdapter()
        defer { withExtendedLifetime(adapter) {} }

        let menu = adapter.makeMenu()
        #expect(titles(of: menu) == ["Insert Pattern", "-", "Recent Queries"])
        #expect(menu.font.pointSize == FindQueryFieldMenuAdapter.menuFontSize)
        let insertPatternItem = try #require(menu.items.first)
        #expect(insertPatternItem.action == #selector(NSFindPatternSearchField.insertPattern(_:)))
        #expect((insertPatternItem.target as AnyObject?) === queryField)
        #expect(menu.items.last?.action == nil, "an item without an action is dimmed")
    }

    @Test("while the query takes no patterns, Insert Pattern is left out rather than dimmed")
    func insertPatternIsLeftOutWhilePatternsAreNotAllowed() {
        let (queryField, adapter) = makeAdapter()
        defer { withExtendedLifetime(adapter) {} }

        queryField.allowsPatternInsertion = false
        #expect(titles(of: adapter.makeMenu()) == ["Recent Queries"])
        adapter.recentQueries = Self.recentQueries
        #expect(titles(of: adapter.makeMenu()).first == "Recent Queries")
    }

    @Test("the recent queries are listed indented under their title, latest first, then Clear Recents")
    func recentQueriesAreListed() {
        let (_, adapter) = makeAdapter()
        defer { withExtendedLifetime(adapter) {} }

        adapter.recentQueries = Self.recentQueries
        let menu = adapter.makeMenu()
        #expect(titles(of: menu) == [
            "Insert Pattern", "-", "Recent Queries",
            "In Indexed Images, text containing “NSView”, match case",
            "In Current Image, members matching word “frame”, ignore case",
            "-", "Clear Recents",
        ])
        let recentQueryItems = Array(menu.items[3 ... 4])
        #expect(recentQueryItems.map(\.indentationLevel) == [1, 1])
        #expect(recentQueryItems.map { $0.attributedTitle?.string } == recentQueryItems.map(\.title))
        #expect(recentQueryItems.allSatisfy { ($0.attributedTitle?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == FindQueryFieldMenuAdapter.menuFontSize })
    }

    @Test("choosing a recent query puts its term in the field and reports the whole query")
    func choosingARecentQuery() throws {
        let (queryField, adapter) = makeAdapter()
        defer { withExtendedLifetime(adapter) {} }

        var chosenQueries: [FindQuery] = []
        let subscription = adapter.recentQuerySelected.emitOnNext { chosenQueries.append($0) }
        defer { subscription.dispose() }

        queryField.stringValue = "being typed"
        adapter.recentQueries = Self.recentQueries
        let menu = adapter.makeMenu()
        try choose(menu.items[4])
        #expect(chosenQueries == [Self.recentQueries[1]])
        #expect(queryField.findPatternComponents == Self.recentQueries[1].term.components)
    }

    @Test("choosing Clear Recents reports it")
    func choosingClearRecents() throws {
        let (_, adapter) = makeAdapter()
        defer { withExtendedLifetime(adapter) {} }

        var clearCount = 0
        let subscription = adapter.clearRecentQueriesSelected.emitOnNext { clearCount += 1 }
        defer { subscription.dispose() }

        adapter.recentQueries = Self.recentQueries
        let menu = adapter.makeMenu()
        try choose(try #require(menu.items.last))
        #expect(clearCount == 1)
    }
}
