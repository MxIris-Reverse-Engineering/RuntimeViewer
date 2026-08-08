import Foundation
import FoundationToolbox
import Ifrit
import FuzzySearch

public enum FilterMode: Int, CaseIterable, Codable, CustomStringConvertible, Sendable {
    case fuzzySearch
    case ifrit

    public var description: String {
        switch self {
        case .fuzzySearch:
            "Fuzzy Search"
        case .ifrit:
            "Ifrit"
        }
    }
}

/// Everything a text-filter pass depends on, bundled so conformers can
/// guard their didSet cascades with a single equality check ("query text
/// unchanged but case toggle flipped" must still re-filter).
struct FilterContext: Equatable, Sendable {
    var query: String = ""
    var isCaseInsensitive: Bool = false
    var mode: FilterMode?

    var isEmpty: Bool { query.isEmpty }
}

/// One match produced by `FilterEngine.match`: which haystack matched and
/// the highlight ranges to render. Verdicts come back in display order
/// (fuzzy modes sort by score, plain contains preserves input order), so
/// callers can build their filtered arrays by straight index mapping.
struct FilterMatchVerdict {
    let haystackIndex: Int
    let result: FuzzyFilterResult?
}

enum FilterEngine {
    /// String-only adapter so the pure `match` path can reuse the
    /// FuzzySearch collection algorithm without touching any cell
    /// view model state.
    private struct FuzzySearchableHaystack: FuzzySearchable {
        let haystackIndex: Int
        let fuzzyStringToMatch: String
    }

    /// Pure matching core: no side effects, safe to call from any thread.
    /// An empty query is the identity filter — every haystack "matches"
    /// with no highlight, in input order — so callers can run one code
    /// path for both searching and clearing.
    static func match(_ context: FilterContext, haystacks: [String]) -> [FilterMatchVerdict] {
        guard !context.isEmpty else {
            return haystacks.indices.map { FilterMatchVerdict(haystackIndex: $0, result: nil) }
        }

        switch context.mode {
        case .fuzzySearch:
            let searchables = haystacks.enumerated().map { haystackIndex, haystack in
                FuzzySearchableHaystack(haystackIndex: haystackIndex, fuzzyStringToMatch: haystack)
            }
            return searchables.fuzzyMatch(context.query).map { matched in
                FilterMatchVerdict(haystackIndex: matched.item.haystackIndex, result: matched.result)
            }
        case .ifrit:
            let fuse = Fuse()
            let sortedResults = fuse.searchSync(context.query, in: haystacks.map { [FuseProp($0)] })
                .map { FuzzySrchResultWrapper($0) }
                .sorted()
            return sortedResults.map { result in
                FilterMatchVerdict(haystackIndex: result.index, result: result)
            }
        case .none:
            // `isCaseInsensitive == true` really means case-insensitive
            // matching now. The pre-2026-08 implementation had the branch
            // inverted; the sidebar's toggle default flipped to `.on` in
            // the same change so the effective default behavior
            // (case-insensitive) is preserved.
            let compareOptions: String.CompareOptions = context.isCaseInsensitive ? [.caseInsensitive] : []
            return haystacks.indices.compactMap { haystackIndex in
                guard haystacks[haystackIndex].range(of: context.query, options: compareOptions) != nil else {
                    return nil
                }
                return FilterMatchVerdict(haystackIndex: haystackIndex, result: nil)
            }
        }
    }

    /// Mutating convenience over `match` for single-level item lists: keeps
    /// each item's stored `filterContext` in sync (conformers guard their
    /// own cascades), assigns `filterResult` for matches, resets it for
    /// misses, and returns the matched items in display order. Conformers
    /// are expected to make a redundant `filterResult = nil` assignment
    /// cheap (see `SidebarRuntimeObjectCellViewModel`), so a keystroke that
    /// changes nothing rebuilds nothing.
    @discardableResult
    static func filter<Item: FilterableItem>(context: FilterContext, items: [Item]) -> [Item] {
        for item in items {
            item.filterContext = context
        }

        let verdicts = match(context, haystacks: items.map(\.filterableString))

        guard !context.isEmpty else {
            for item in items {
                item.filterResult = nil
            }
            return items
        }

        var isMatchedByIndex = [Bool](repeating: false, count: items.count)
        var filteredItems: [Item] = []
        filteredItems.reserveCapacity(verdicts.count)
        for verdict in verdicts {
            isMatchedByIndex[verdict.haystackIndex] = true
            let item = items[verdict.haystackIndex]
            item.filterResult = verdict.result
            filteredItems.append(item)
        }
        for (itemIndex, item) in items.enumerated() where !isMatchedByIndex[itemIndex] {
            item.filterResult = nil
        }
        return filteredItems
    }
}

protocol FilterableItem: AnyObject {
    var filterContext: FilterContext { set get }
    var filterResult: FuzzyFilterResult? { set get }
    var filterableString: String { get }
}

protocol FuzzyFilterResult {
    var ranges: [NSRange] { get }
}

@dynamicMemberLookup
struct FuzzySrchResultWrapper: ComparableBuildable {
    let wrappedValue: FuzzySrchResult

    init(_ wrappedValue: FuzzySrchResult) {
        self.wrappedValue = wrappedValue
    }

    var resultsScore: Double {
        wrappedValue.results.reduce(0) { $0 + $1.diffScore }
    }

    subscript<Value>(dynamicMember keyPath: KeyPath<FuzzySrchResult, Value>) -> Value {
        wrappedValue[keyPath: keyPath]
    }

    static var comparableDefinition: some ComparisonStep<Self> {
        compare(\.wrappedValue.diffScore)
        compare(\.resultsScore)
    }
}

extension FuzzySrchResultWrapper: FuzzyFilterResult {
    var ranges: [NSRange] {
        wrappedValue.results.flatMap { $0.ranges.map { NSRange($0) } }
    }
}

extension FuzzySearchResult: FuzzyFilterResult {
    var ranges: [NSRange] {
        parts
    }
}
