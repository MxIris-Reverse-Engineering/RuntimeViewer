import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore

/// The naming word cloud's ranking order and the defaults the window opens
/// with: the most common word first, a header click choosing a column or
/// reversing it, equal counts ordered by word, and the word limit the cloud
/// starts at.
@Suite("Naming word ranking order")
struct NamingWordRankingOrderTests {
    private static let owner = RuntimeObject(
        name: "Widget",
        displayName: "Widget",
        kind: .objc(.type(.class)),
        imagePath: "/System/Library/Frameworks/Test.framework/Test",
        children: [],
        properties: []
    )

    /// A word held by `count` names.
    private static func word(_ text: String, count: Int) -> NamingWordCloudWord {
        NamingWordCloudWord(NamingWordCount(key: text.lowercased(), word: text, category: .class, usages: Array(repeating: .type(owner), count: count)))
    }

    private static let words = [
        word("View", count: 12),
        word("cell", count: 3),
        word("Manager", count: 7),
        word("Button", count: 3),
        word("Animation", count: 7),
    ]

    @Test("the ranking opens with the most common word first, equal counts ordered by word")
    func rankingDefaultsToCountDescending() {
        let sorted = NamingWordRankingOrder.mostCommonFirst.sorted(Self.words)

        #expect(sorted.map(\.word) == ["View", "Animation", "Manager", "Button", "cell"])
    }

    @Test("a click on Word orders the words from A, and a second click reverses them")
    func rankingSortsByWordThenReverses() {
        let byWord = NamingWordRankingOrder.mostCommonFirst.choosing(.word)
        let byWordReversed = byWord.choosing(.word)

        #expect(byWord == NamingWordRankingOrder(column: .word, isAscending: true))
        #expect(byWord.sorted(Self.words).map(\.word) == ["Animation", "Button", "cell", "Manager", "View"])
        #expect(byWordReversed == NamingWordRankingOrder(column: .word, isAscending: false))
        #expect(byWordReversed.sorted(Self.words).map(\.word) == ["View", "Manager", "cell", "Button", "Animation"])
    }

    @Test("Count goes back to the most common first, and reverses to the least common first with equal counts still by word")
    func equalCountsAreOrderedByWord() {
        let byCount = NamingWordRankingOrder(column: .word, isAscending: true).choosing(.count)
        let leastCommonFirst = byCount.choosing(.count)

        #expect(byCount == .mostCommonFirst)
        #expect(leastCommonFirst.sorted(Self.words).map(\.word) == ["Button", "cell", "Animation", "Manager", "View"])
    }

    @Test("the cloud starts with 150 words")
    func defaultWordLimitIs150() {
        #expect(NamingWordCloudPreferences().wordLimit == 150)
        #expect(NamingWordCloudPreferences.wordLimitChoices.contains(150))
    }

    @Test("the usage list's second column is a type's kind, or a member's declaring type")
    func usageDetailColumnFollowsMeasure() {
        #expect(NamingWordMeasure.typeSuffixes.usageDetailTitle == "Kind")
        #expect(NamingWordMeasure.typeWords.usageDetailTitle == "Kind")
        #expect(NamingWordMeasure.memberWords.usageDetailTitle == "Declared In")
        #expect(NamingWordMeasure.methodFirstWords.usageDetailTitle == "Declared In")
    }
}
