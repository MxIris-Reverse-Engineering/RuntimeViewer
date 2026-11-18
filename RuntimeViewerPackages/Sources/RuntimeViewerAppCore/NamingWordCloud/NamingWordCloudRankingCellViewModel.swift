#if os(macOS)

import Foundation

/// A row of the naming word cloud's ranking: the word, preceded by a dot of its
/// category's colour, and how many names hold it. Fully determined by the word,
/// so the list builds it in its cell provider (`DifferentiableBox`).
public final class NamingWordCloudRankingCellViewModel: CellViewModel, @unchecked Sendable {
    public struct Appearance: Equatable, Sendable {
        public let word: String
        public let count: String
        public let dotColor: ColorDescriptor
    }

    public let word: NamingWordCloudWord

    public let appearance: Appearance

    public init(word: NamingWordCloudWord) {
        self.word = word
        appearance = Appearance(word: word.word, count: word.count.formatted(), dotColor: word.color)
        super.init()
    }
}

#endif
