import Foundation

/// The order Open Quickly lists fuzzy matches in, best first: File › Open Quickly…'s bar and an
/// empty editor pane's start page over the engine's images and indexed objects (proposal
/// `editor-start-page`). It began as the ranking of the sidebar's own Open Quickly, which searched
/// one image's objects and is gone.
///
/// `FuzzySearchable.fuzzyMatch` stops accumulating once the pattern is consumed —
/// `hasPrefix(_:atIndex:)` compares against the empty suffix from then on and always fails — so
/// every haystack containing the query as one contiguous run scores the *same* constant, whichever
/// name it is, however long, wherever the run sits. A four-character query ties every such name at
/// 1+3+7+15 = 26. Weight alone therefore leaves the whole tie in input order and a cap keeps
/// whichever names come first: on AppKit, `vi` ties 875 names and drops `NSView` at position 502.
///
/// The tie-breakers restore what a jump-to palette needs. A haystack may be a name followed by more
/// text, so a match ending within the name's own length is a hit on the item itself rather than on
/// one of its members — the catalog's haystacks are names alone, for which this always holds. Then
/// the earlier match, then the shorter name; the trailing name compare only makes the order
/// deterministic.
///
/// Two things to fix before a filter mode other than `.fuzzySearch` is ever ranked here:
/// `ranges.last` assumes ascending ranges, which holds for `FuzzySearchResult.parts` but not for
/// the Ifrit wrapper's `results.flatMap` (use `map(end).max()` instead), and `relevanceWeight`
/// drops the secondary `resultsScore` key that Ifrit's own `comparableDefinition` carries.
enum OpenQuicklyRanking {
    /// The best `limit` of `verdicts`, best first. `displayName` gives the name of the item behind a
    /// haystack index — the part of its haystack that is the item's own name.
    ///
    /// Asks `displayName` about *every* verdict, not only the ones that survive the cap, so a
    /// haystack index with no item traps here rather than only when such a row is displayed.
    static func rank(
        _ verdicts: [FilterMatchVerdict],
        limit: Int,
        displayName: (_ haystackIndex: Int) -> String
    ) -> [FilterMatchVerdict] {
        struct RankingKey {
            let weight: Double
            let matchesOwnName: Bool
            let firstMatchLocation: Int
            let displayNameLength: Int
            let displayName: String
        }

        let rankedVerdicts = verdicts.map { verdict -> (verdict: FilterMatchVerdict, key: RankingKey) in
            let itemDisplayName = displayName(verdict.haystackIndex)
            let displayNameLength = itemDisplayName.count
            let ranges = verdict.result?.ranges ?? []
            let lastMatchEnd = ranges.last.map { $0.location + $0.length } ?? 0
            let key = RankingKey(
                weight: verdict.result?.relevanceWeight ?? 0,
                matchesOwnName: lastMatchEnd <= displayNameLength,
                firstMatchLocation: ranges.first?.location ?? displayNameLength,
                displayNameLength: displayNameLength,
                displayName: itemDisplayName
            )
            return (verdict, key)
        }

        return rankedVerdicts
            .sorted { left, right in
                if left.key.weight != right.key.weight {
                    return left.key.weight > right.key.weight
                }
                if left.key.matchesOwnName != right.key.matchesOwnName {
                    return left.key.matchesOwnName
                }
                if left.key.firstMatchLocation != right.key.firstMatchLocation {
                    return left.key.firstMatchLocation < right.key.firstMatchLocation
                }
                if left.key.displayNameLength != right.key.displayNameLength {
                    return left.key.displayNameLength < right.key.displayNameLength
                }
                return left.key.displayName < right.key.displayName
            }
            .prefix(limit)
            .map(\.verdict)
    }
}
