import Foundation
import Testing
@testable import RuntimeViewerApplication

/// Contract suite for `FilterEngine`'s case-sensitivity semantics.
///
/// History: the pre-2026-08 `.none` (plain contains) branch had the flag
/// inverted — `isCaseInsensitive == true` selected the case-*sensitive*
/// `contains`. When the engine was fixed to honor the flag, every caller
/// supplying a constant had to flip with it; the UIKit sidebar's
/// `.just(false)` was missed and shipped iOS a case-sensitive search
/// (PR #88 review, finding 2). These tests pin the honest semantics at the
/// engine so a future inversion breaks loudly here instead of silently
/// flipping whichever platform forgot to compensate.
@Suite("FilterEngineCaseSensitivity")
struct FilterEngineCaseSensitivityTests {
    private let haystacks = ["NSString", "NSAttributedString", "UIView"]

    @Test("plain contains honors isCaseInsensitive = true")
    func caseInsensitiveMatchesDifferentCase() {
        let context = FilterContext(query: "nsstring", isCaseInsensitive: true, mode: nil)
        let matchedIndices = FilterEngine.match(context, haystacks: haystacks).map(\.haystackIndex)
        #expect(matchedIndices == [0], "lowercase query must match differently-cased haystacks when the flag is on")
    }

    @Test("plain contains honors isCaseInsensitive = false")
    func caseSensitiveRequiresExactCase() {
        let differentCase = FilterContext(query: "nsstring", isCaseInsensitive: false, mode: nil)
        #expect(
            FilterEngine.match(differentCase, haystacks: haystacks).isEmpty,
            "a case-sensitive query must not match differently-cased haystacks"
        )

        let exactCase = FilterContext(query: "NSString", isCaseInsensitive: false, mode: nil)
        let matchedIndices = FilterEngine.match(exactCase, haystacks: haystacks).map(\.haystackIndex)
        #expect(matchedIndices == [0])
    }

    @Test("an empty query is the identity filter regardless of the flag")
    func emptyQueryIsIdentity() {
        for isCaseInsensitive in [true, false] {
            let context = FilterContext(query: "", isCaseInsensitive: isCaseInsensitive, mode: nil)
            let matchedIndices = FilterEngine.match(context, haystacks: haystacks).map(\.haystackIndex)
            #expect(matchedIndices == [0, 1, 2])
        }
    }

    @Test("filter(context:items:) resets results and stamps the context on the empty-query path")
    func emptyQueryFilterResetsItems() {
        let items = haystacks.map(StubFilterableItem.init)
        items[1].filterResult = StubFilterResult()

        let emptyContext = FilterContext(query: "", isCaseInsensitive: true, mode: nil)
        let returnedItems = FilterEngine.filter(context: emptyContext, items: items)

        #expect(returnedItems.count == items.count)
        for item in items {
            #expect(item.filterContext == emptyContext, "the context must be stamped before the empty-query early return")
            #expect(item.filterResult == nil)
        }
    }

    private final class StubFilterableItem: FilterableItem {
        var filterContext = FilterContext()
        var filterResult: FuzzyFilterResult?
        let filterableString: String

        init(_ filterableString: String) {
            self.filterableString = filterableString
        }
    }

    private struct StubFilterResult: FuzzyFilterResult {
        var ranges: [NSRange] { [] }
    }
}
