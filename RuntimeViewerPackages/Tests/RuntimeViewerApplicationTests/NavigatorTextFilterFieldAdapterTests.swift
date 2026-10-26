import AppKit
import AppKitPlus
import Dependencies
import Foundation
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// `NavigatorTextFilterFieldAdapter`: a sidebar page's token field set up as Xcode's navigator filter — text tokens, the
/// four comparisons with their value marks, no ANY / ALL — reporting a `NavigatorTextFilter`, and keeping one list of
/// recent filters for each group of pages. The fields are real ones, off screen, and every test has a store of its own.
/// Serialized because one test posts a menu action, which makes every live page save.
@Suite("NavigatorTextFilterFieldAdapter", .serialized)
@MainActor
struct NavigatorTextFilterFieldAdapterTests {
    /// Internal, not private: a parameterized test takes it as its argument.
    typealias Term = NavigatorTextFilter.Term

    private typealias RecentFiltersGroup = NavigatorTextFilterFieldAdapter.RecentFiltersGroup

    private static let beginsWithNS = Term(comparison: .beginsWith, value: "NS")

    private static let excludingController = Term(comparison: .doesNotContain, value: "Controller")

    private static let containingView = Term(comparison: .contains, value: "View")

    private func makePage(
        group: RecentFiltersGroup = .runtimeObjectList,
        appDefaults: AppDefaults
    ) -> (filterField: NSFilterTokenField, adapter: NavigatorTextFilterFieldAdapter) {
        let filterField = NSFilterTokenField(frame: NSRect(x: 0, y: 0, width: 240, height: 22))
        let adapter = withDependencies {
            $0.appDefaults = appDefaults
        } operation: {
            NavigatorTextFilterFieldAdapter(filterField: filterField, recentFiltersGroup: group)
        }
        return (filterField, adapter)
    }

    private func tokens(_ terms: Term...) -> [NSFilterToken] {
        terms.map(NavigatorTextFilterFieldAdapter.token(for:))
    }

    /// The recent filters of a saved field state, newest first, each as the text of its tokens.
    ///
    /// The field has no API that lists them, so they are read from the state itself: its root object is AppKitPlus's
    /// private `_NSFilterTokenFieldState`, whose `recentFilterItems` are the recent filters and whose `objectValue`
    /// holds a filter's tokens.
    private func recentFilters(in state: Data?) throws -> [[String]] {
        guard let state else { return [] }
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: state)
        unarchiver.requiresSecureCoding = false
        let rootObject = try #require(unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject)
        let recentFilterItems = rootObject.value(forKey: "recentFilterItems") as? [NSObject] ?? []
        return recentFilterItems.map { recentFilterItem in
            (recentFilterItem.value(forKey: "objectValue") as? [Any] ?? [])
                .compactMap { $0 as? NSFilterToken }
                .map { NavigatorTextFilter.editingString(for: NavigatorTextFilterFieldAdapter.term(for: $0)) }
        }
    }

    private func savedState(of group: RecentFiltersGroup = .runtimeObjectList, in appDefaults: AppDefaults) -> Data? {
        appDefaults.navigatorFilterFieldStates[group.rawValue]
    }

    // MARK: - The field

    @Test("the field gets one untitled token type, the four comparisons with Xcode's value marks, and no operator or completions")
    func configuresTheFieldAsXcodesNavigatorFilter() {
        let (filterField, adapter) = makePage(appDefaults: .isolated())
        defer { withExtendedLifetime(adapter) {} }

        #expect((filterField.delegate as AnyObject?) === adapter)
        #expect(filterField.tokenTypes.map(\.identifier) == ["text"])
        #expect(filterField.tokenTypes.first?.title == "")
        #expect(filterField.defaultTokenType?.identifier == "text")
        #expect(filterField.comparisonTypes.map(\.identifier) == ["contains", "doesNotContain", "beginsWith", "endsWith"])
        #expect(filterField.comparisonTypes.map(\.title) == ["Contains", "Does Not Contain", "Begins With", "Ends With"])
        #expect(filterField.comparisonTypes.map(\.isExclusion) == [false, true, false, false])
        #expect(filterField.comparisonTypes.map(\.valuePrefix) == [nil, nil, nil, "\u{22EF}"])
        #expect(filterField.comparisonTypes.map(\.valueSuffix) == [nil, nil, "\u{22EF}", nil])
        #expect(filterField.defaultComparisonType?.identifier == "contains")
        #expect(filterField.operatorDisplayMode == .never)
        #expect(filterField.recentFiltersEnabled)
        #expect(!adapter.responds(to: NSSelectorFromString("filterTokenField:completionsForString:completionHandler:")))
    }

    // MARK: - Text and tokens

    @Test("typed text turns into Xcode's text tokens, and a pattern's comparison is not one the field offers")
    func typedTextTurnsIntoTextTokens() throws {
        let (filterField, adapter) = makePage(appDefaults: .isolated())
        defer { withExtendedLifetime(adapter) {} }

        let tokens = try #require(adapter.filterTokenField(filterField, tokensFor: "loo !bar baz* *qux lib*Core"))
        #expect(tokens.map(\.type.identifier) == ["text", "text", "text", "text", "text"])
        #expect(tokens.map { $0.comparisonType?.identifier } == ["contains", "doesNotContain", "beginsWith", "endsWith", "like"])
        #expect(tokens.map(\.value) == ["loo", "bar", "baz", "qux", "lib*Core"])
        // A token whose comparison the field does not offer gets no menu.
        let patternComparisonType = try #require(tokens.last?.comparisonType)
        #expect(!filterField.comparisonTypes.contains(patternComparisonType))
        #expect(adapter.filterTokenField(filterField, tokensFor: "   ") == [])
    }

    @Test("a token's editing string parses back into the same token, a space in its value included", arguments: [
        Term(comparison: .contains, value: "loo"),
        Term(comparison: .doesNotContain, value: "loo"),
        Term(comparison: .beginsWith, value: "loo"),
        Term(comparison: .endsWith, value: "loo"),
        Term(comparison: .like, value: "lib*Co?e"),
        Term(comparison: .contains, value: "big view"),
    ])
    func editingStringsParseBack(term: Term) throws {
        let (filterField, adapter) = makePage(appDefaults: .isolated())
        defer { withExtendedLifetime(adapter) {} }

        let editingString = try #require(adapter.filterTokenField(filterField, editingStringFor: NavigatorTextFilterFieldAdapter.token(for: term)))
        let reparsedTokens = try #require(adapter.filterTokenField(filterField, tokensFor: editingString))
        #expect(reparsedTokens.map(NavigatorTextFilterFieldAdapter.term(for:)) == [term], "editing string: \(editingString)")
    }

    @Test("a token from another field reads as Contains, or as Does Not Contain when it is an exclusion")
    func foreignTokensReadAsContains() {
        let kindType = NSFilterTokenType(identifier: "kind", title: "Kind")
        let isNot = NSFilterTokenComparisonType(identifier: "isNot", title: "is not", exclusion: true)
        let isEqual = NSFilterTokenComparisonType(identifier: "is", title: "is", exclusion: false)

        #expect(NavigatorTextFilterFieldAdapter.term(for: NSFilterToken(type: kindType, comparisonType: isNot, value: "error")) == Term(comparison: .doesNotContain, value: "error"))
        #expect(NavigatorTextFilterFieldAdapter.term(for: NSFilterToken(type: kindType, comparisonType: isEqual, value: "error")) == Term(comparison: .contains, value: "error"))
        #expect(NavigatorTextFilterFieldAdapter.term(for: NSFilterToken(type: kindType, comparisonType: nil, value: "error")) == Term(comparison: .contains, value: "error"))
    }

    // MARK: - Reporting

    @Test("a change of tokens is reported as the filter, and clearing empties the field and reports the empty filter")
    func reportsTheFilterAndClears() async throws {
        let (filterField, adapter) = makePage(appDefaults: .isolated())
        defer { withExtendedLifetime(adapter) {} }
        var reportedFilters: [NavigatorTextFilter] = []
        let subscription = adapter.filter.emitOnNext { reportedFilters.append($0) }
        defer { subscription.dispose() }

        filterField.filterTokens = tokens(Self.beginsWithNS, Self.excludingController)
        let expectedFilter = NavigatorTextFilter(terms: [Self.beginsWithNS, Self.excludingController])
        let reported = await pollUntil(timeout: .seconds(5)) { reportedFilters.last == expectedFilter }
        #expect(reported, "reported: \(reportedFilters)")
        #expect(adapter.currentFilter == expectedFilter)

        adapter.clear()
        let cleared = await pollUntil(timeout: .seconds(5)) { reportedFilters.last == .empty }
        #expect(cleared, "reported: \(reportedFilters)")
        #expect(filterField.filterTokens.isEmpty)
    }

    // MARK: - Recent filters

    @Test("a change of tokens saves the field's state for its group")
    func savesTheStateWhenTheTokensChange() {
        let appDefaults = AppDefaults.isolated()
        let (filterField, adapter) = makePage(appDefaults: appDefaults)
        defer { withExtendedLifetime(adapter) {} }

        #expect(savedState(in: appDefaults) == nil)
        filterField.filterTokens = tokens(Self.beginsWithNS)
        // A read waits for the write before it.
        #expect(savedState(in: appDefaults) == filterField.encodedState)
    }

    @Test("a new page reads its group's recent filters, and the filter in use joins them instead of coming back")
    func newPageReadsTheRecentFilters() throws {
        let appDefaults = AppDefaults.isolated()
        let (firstFilterField, firstAdapter) = makePage(appDefaults: appDefaults)
        defer { withExtendedLifetime(firstAdapter) {} }
        firstFilterField.filterTokens = tokens(Self.beginsWithNS)
        firstFilterField.filterTokens = tokens(Self.excludingController)
        #expect(try recentFilters(in: savedState(in: appDefaults)) == [["NS*"]])

        let (secondFilterField, secondAdapter) = makePage(appDefaults: appDefaults)
        defer { withExtendedLifetime(secondAdapter) {} }

        #expect(secondFilterField.filterTokens.isEmpty)
        #expect(secondAdapter.currentFilter == .empty)
        #expect(try recentFilters(in: secondFilterField.encodedState) == [["!Controller"], ["NS*"]])
    }

    @Test("Clear Recents, which the field does not report, is saved after the menu action")
    func clearRecentsIsSavedAfterTheMenuAction() async throws {
        let appDefaults = AppDefaults.isolated()
        let (filterField, adapter) = makePage(appDefaults: appDefaults)
        defer { withExtendedLifetime(adapter) {} }
        filterField.filterTokens = tokens(Self.beginsWithNS)
        filterField.filterTokens = tokens(Self.excludingController)

        filterField.clearRecentFilters()
        // The field tells its delegate nothing: the saved list is the old one until a menu action.
        #expect(try recentFilters(in: savedState(in: appDefaults)) == [["NS*"]])

        NotificationCenter.default.post(name: NSMenu.didSendActionNotification, object: NSMenu())
        let saved = try await pollUntil(timeout: .seconds(5)) {
            try recentFilters(in: savedState(in: appDefaults)).isEmpty
        }
        let savedRecentFilters = try recentFilters(in: savedState(in: appDefaults))
        #expect(saved, "saved: \(savedRecentFilters)")
    }

    @Test("an empty page takes up the recent filters another page of its group saves")
    func emptyPageTakesUpRecentFiltersSavedElsewhere() async throws {
        let appDefaults = AppDefaults.isolated()
        let (firstFilterField, firstAdapter) = makePage(appDefaults: appDefaults)
        let (secondFilterField, secondAdapter) = makePage(appDefaults: appDefaults)
        defer { withExtendedLifetime((firstAdapter, secondAdapter)) {} }

        firstFilterField.filterTokens = tokens(Self.beginsWithNS)
        firstFilterField.filterTokens = tokens(Self.excludingController)

        let tookUp = try await pollUntil(timeout: .seconds(5)) {
            try recentFilters(in: secondFilterField.encodedState) == [["!Controller"], ["NS*"]]
        }
        let secondRecentFilters = try recentFilters(in: secondFilterField.encodedState)
        #expect(tookUp, "second page: \(secondRecentFilters)")
        #expect(secondFilterField.filterTokens.isEmpty)
    }

    @Test("a page with a filter keeps its filter and its own recent filters when another page saves")
    func pageWithAFilterKeepsItsOwn() async throws {
        let appDefaults = AppDefaults.isolated()
        let (firstFilterField, firstAdapter) = makePage(appDefaults: appDefaults)
        let (secondFilterField, secondAdapter) = makePage(appDefaults: appDefaults)
        // Empty, so it shows when the saved state has reached the pages made before it.
        let (thirdFilterField, thirdAdapter) = makePage(appDefaults: appDefaults)
        defer { withExtendedLifetime((firstAdapter, secondAdapter, thirdAdapter)) {} }
        secondFilterField.filterTokens = tokens(Self.containingView)

        firstFilterField.filterTokens = tokens(Self.beginsWithNS)
        firstFilterField.filterTokens = tokens(Self.excludingController)
        let reachedThePages = try await pollUntil(timeout: .seconds(5)) {
            try recentFilters(in: thirdFilterField.encodedState) == [["!Controller"], ["NS*"]]
        }
        #expect(reachedThePages)

        #expect(secondFilterField.filterTokens.map(NavigatorTextFilterFieldAdapter.term(for:)) == [Self.containingView])
        #expect(try recentFilters(in: secondFilterField.encodedState).isEmpty)
    }

    @Test("each group keeps a list of its own")
    func groupsKeepSeparateLists() throws {
        let appDefaults = AppDefaults.isolated()
        let (imageListFilterField, imageListAdapter) = makePage(group: .imageList, appDefaults: appDefaults)
        defer { withExtendedLifetime(imageListAdapter) {} }
        imageListFilterField.filterTokens = tokens(Self.beginsWithNS)
        imageListFilterField.filterTokens = tokens(Self.excludingController)

        let (reportFilterField, reportAdapter) = makePage(group: .report, appDefaults: appDefaults)
        defer { withExtendedLifetime(reportAdapter) {} }

        #expect(try recentFilters(in: reportFilterField.encodedState).isEmpty)
        #expect(savedState(of: .report, in: appDefaults) == nil)
        #expect(try recentFilters(in: savedState(of: .imageList, in: appDefaults)) == [["NS*"]])
    }
}
