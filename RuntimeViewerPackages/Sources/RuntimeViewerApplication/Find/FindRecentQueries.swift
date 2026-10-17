import Foundation
#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
import AppKitPlus
#endif

/// The Find navigator's recent queries — the Recent Queries section of the query field's menu —
/// kept as Xcode's `IDEFindNavigatorQueryHistoryManager` keeps its own: the latest first, ten at
/// most (`-addQueryHistoryItem:`), a search run again moved to the front instead of listed twice.
/// Xcode keeps them per workspace; here they are kept per source, in
/// `AppDefaults.findRecentQueriesByScope`, and outlive the app.
///
/// A query is recorded when the user runs it — Return in the query field, or a recent query chosen
/// from the menu — never when it runs again by itself on another engine, under other Generation
/// Options or over a corpus built later.
enum FindRecentQueries {
    /// Xcode's limit.
    static let maximumCount = 10

    /// `recentQueries` with `query` first, the same search dropped from further down, and at most
    /// `maximumCount` of them. An empty query is not recorded.
    static func recording(_ query: FindQuery, in recentQueries: [FindQuery]) -> [FindQuery] {
        guard !query.isEmpty else { return recentQueries }
        var updated = recentQueries.filter { !$0.searchesTheSame(as: query) }
        updated.insert(query, at: 0)
        return Array(updated.prefix(maximumCount))
    }

    /// `text containing`, `regular expression`, `ancestor types starting with`, `ObjC Method
    /// members ending with`, `call hierarchy of`: what a query searches, as the middle of its
    /// title.
    static func searchDescription(of query: FindQuery) -> String {
        switch query.mode {
        case .text:
            "text \(query.textMatchStyle.title.lowercased())"
        case .regularExpression:
            "regular expression"
        case .ancestorTypes, .descendantTypes, .conformingTypes:
            "\(query.mode.title.lowercased()) \(query.textMatchStyle.title.lowercased())"
        case .members:
            "\(membersDescription(of: query.memberKindFilter)) \(memberMatchStyleDescription(of: query.memberMatchStyle))"
        case .callHierarchy, .callees, .typeReferences:
            // A command names its root, which no match style applies to.
            query.crossReferenceRoot == nil
                ? "\(query.mode.title.lowercased()) \(query.textMatchStyle.title.lowercased())"
                : "\(query.mode.title.lowercased()) of"
        }
    }

    private static func membersDescription(of memberKindFilter: FindMemberKindFilter) -> String {
        switch memberKindFilter {
        case .any: "members"
        case .kind(let kind): "\(kind.displayName) members"
        }
    }

    private static func memberMatchStyleDescription(of memberMatchStyle: FindMemberMatchStyle) -> String {
        switch memberMatchStyle {
        case .regularExpression: "matching regular expression"
        default: memberMatchStyle.title.lowercased()
        }
    }

    /// `In Indexed Images, text containing “NSView”, ignore case`: Xcode's title for a recent query
    /// (`-[IDEFindNavigatorQueryParametersController descriptionForHistoryItem:withFont:inWorkspace:]`),
    /// the patterns left out — the plain title of the menu item, which `attributedTitle(for:font:)`
    /// draws over.
    static func title(for query: FindQuery) -> String {
        "\(query.scope.title), \(searchDescription(of: query)) “\(query.term.plainText)”, \(caseDescription(of: query))"
    }

    private static func caseDescription(of query: FindQuery) -> String {
        query.isCaseSensitive ? "match case" : "ignore case"
    }

    #if canImport(AppKit) && !targetEnvironment(macCatalyst)
    /// `title(for:)` with the patterns drawn between the quotes as the query field draws them.
    @MainActor
    static func attributedTitle(for query: FindQuery, font: NSFont?) -> NSAttributedString {
        var textAttributes: [NSAttributedString.Key: Any] = [:]
        if let font {
            textAttributes[.font] = font
        }
        let attributedTitle = NSMutableAttributedString(string: "\(query.scope.title), \(searchDescription(of: query)) “", attributes: textAttributes)
        attributedTitle.append(query.term.components.attributedString(font: font, textColor: nil))
        attributedTitle.append(NSAttributedString(string: "”, \(caseDescription(of: query))", attributes: textAttributes))
        return attributedTitle
    }
    #endif
}

extension FindQuery {
    /// Whether the two queries search for the same thing: equal but for the identifiers the query
    /// field gives its tokens, which differ between two queries typed apart.
    func searchesTheSame(as other: FindQuery) -> Bool {
        var withoutTerm = self
        var otherWithoutTerm = other
        withoutTerm.term = FindQueryTerm()
        otherWithoutTerm.term = FindQueryTerm()
        return withoutTerm == otherWithoutTerm && term.searchIdentity == other.term.searchIdentity
    }
}
