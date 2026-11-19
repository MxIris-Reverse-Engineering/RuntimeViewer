import Foundation

/// How the naming word cloud's ranking lists its words: by count or by word,
/// in either direction. A click on a column's header picks that column, or
/// reverses it when it is already the one the ranking follows.
public struct NamingWordRankingOrder: Hashable, Sendable {
    /// The column the ranking follows.
    public enum Column: Hashable, Sendable {
        case word
        case count

        /// The direction a column starts in: the most common word first,
        /// words from A.
        var startsAscending: Bool {
            switch self {
            case .word: true
            case .count: false
            }
        }
    }

    public let column: Column

    public let isAscending: Bool

    public init(column: Column, isAscending: Bool) {
        self.column = column
        self.isAscending = isAscending
    }

    /// The most common word first, which is how the window opens.
    public static let mostCommonFirst = NamingWordRankingOrder(column: .count, isAscending: false)

    /// The order after a click on `clickedColumn`'s header: the same column
    /// reversed, or another column in the direction it starts in.
    public func choosing(_ clickedColumn: Column) -> NamingWordRankingOrder {
        if clickedColumn == column {
            NamingWordRankingOrder(column: column, isAscending: !isAscending)
        } else {
            NamingWordRankingOrder(column: clickedColumn, isAscending: clickedColumn.startsAscending)
        }
    }

    /// `words` in this order. Equal counts fall back to the words from A,
    /// compared without regard to case or to the user's language, so the
    /// order is the same everywhere.
    public func sorted(_ words: [NamingWordCloudWord]) -> [NamingWordCloudWord] {
        words.sorted { lhs, rhs in
            let wordComparison = lhs.word.compare(rhs.word, options: [.caseInsensitive])
            switch column {
            case .word:
                if wordComparison != .orderedSame {
                    return isAscending ? wordComparison == .orderedAscending : wordComparison == .orderedDescending
                }
                return lhs.key < rhs.key
            case .count:
                if lhs.count != rhs.count {
                    return isAscending ? lhs.count < rhs.count : lhs.count > rhs.count
                }
                if wordComparison != .orderedSame {
                    return wordComparison == .orderedAscending
                }
                return lhs.key < rhs.key
            }
        }
    }
}
