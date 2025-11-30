import Foundation
import FoundationToolbox
import Ifrit
import FuzzySearch

public enum FilterMode: Int, CaseIterable, Codable, CustomStringConvertible {
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

enum FilterEngine {
    @dynamicMemberLookup
    private struct FuzzySearchableBox<Item: FilterableItem>: FuzzySearchable {
        let wrappedValue: Item

        init(_ wrappedValue: Item) {
            self.wrappedValue = wrappedValue
        }

        var fuzzyStringToMatch: String { wrappedValue.filterableString }

        subscript<Value>(dynamicMember keyPath: KeyPath<Item, Value>) -> Value {
            wrappedValue[keyPath: keyPath]
        }
    }

    static func filter<Item: FilterableItem>(_ filter: String, items: [Item], mode: FilterMode?) -> [Item] {
        for item in items {
            item.filter = filter
            item.filterResult = nil
        }
        guard !filter.isEmpty else {
            for item in items {
                item.filterResult = nil
            }
            return items
        }

        switch mode {
        case .fuzzySearch:
            let results = items.map { FuzzySearchableBox($0) }.fuzzyMatch(filter)
            var filteredItems: [Item] = []
            for result in results {
                let item = result.item.wrappedValue
                item.filterResult = result.result
                filteredItems.append(item)
            }
            return filteredItems
        case .ifrit:
            let fuse = Fuse()
            let results = fuse.searchSync(filter, in: items.map { [FuseProp($0.filterableString)] }).map { FuzzySrchResultWrapper($0) }.sorted()
            var filteredItems: [Item] = []
            for result in results {
                let item = items[result.index]
                item.filterResult = result
                filteredItems.append(item)
            }
            return filteredItems
        case .none:
            return items.filter { $0.filterableString.localizedCaseInsensitiveContains(filter) }
        }
    }
}

protocol FilterableItem: AnyObject {
    var filter: String { set get }
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

    static var comparableDefinition: ComparableDefinition<FuzzySrchResultWrapper> = makeComparable {
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
