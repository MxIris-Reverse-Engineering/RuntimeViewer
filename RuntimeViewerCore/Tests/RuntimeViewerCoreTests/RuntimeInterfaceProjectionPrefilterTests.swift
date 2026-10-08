import Foundation
import Semantic
import Testing
@testable import RuntimeViewerCore

/// The text search's shortcut past the projection: under options that hide
/// something, an entry is skipped only when the text those options show
/// cannot hold a hit. Skipping an entry with a hit loses a result, so the
/// shortcut has to be exact in that direction.
///
/// The cases spell out by hand the projected text, the shortcut's answer and
/// whether the projection really has a hit. The sweep then checks the one
/// rule against the projection and the matcher themselves over thousands of
/// seeded texts.
@Suite("Text search projection prefilter")
struct RuntimeInterfaceProjectionPrefilterTests {
    /// One run of an interface's text.
    struct Segment: Sendable, CustomStringConvertible {
        enum Visibility: Sendable {
            /// In no region: shown whatever the options.
            case plain
            /// In a region whose condition no options satisfy.
            case hidden
            /// In a region whose condition every options satisfy.
            case shownByItsCondition
        }

        let text: String
        let visibility: Visibility

        static func plain(_ text: String) -> Segment {
            Segment(text: text, visibility: .plain)
        }

        static func hidden(_ text: String) -> Segment {
            Segment(text: text, visibility: .hidden)
        }

        static func shownByItsCondition(_ text: String) -> Segment {
            Segment(text: text, visibility: .shownByItsCondition)
        }

        var description: String {
            switch visibility {
            case .plain: "\"\(text)\""
            case .hidden: "[hidden \"\(text)\"]"
            case .shownByItsCondition: "[shown \"\(text)\"]"
            }
        }
    }

    struct PrefilterCase: Sendable, CustomTestStringConvertible {
        let segments: [Segment]
        let query: String
        let matchMode: RuntimeInterfaceSearchMatchMode
        var isCaseSensitive = false
        let projectedText: String
        let mayHaveHits: Bool
        let projectionHasHit: Bool
        let testDescription: String
    }

    /// No printer knows these options, so `RuntimeInterfaceVisibility` reads
    /// them as off whatever Generation Options it is given: a region under
    /// either of the first two conditions is hidden, one under the third is
    /// shown. Hidden runs alternate between the first two, so two that touch
    /// stay two regions, as a table keeps them.
    private static let conditions: [VisibilityCondition] = [
        .enabled("test.optionNoPrinterKnows"),
        .enabled("test.otherOptionNoPrinterKnows"),
        .disabled("test.optionNoPrinterKnows"),
    ]

    private static let visibility = RuntimeInterfaceVisibility(.mcp)

    private static func entry(_ segments: [Segment]) -> RuntimeInterfaceCorpusEntry {
        var text = ""
        var regions: [VisibilityRegionTable.Region] = []
        var hiddenSegmentCount = 0
        for segment in segments {
            let utf8Offset = UInt32(text.utf8.count)
            let utf8Length = UInt32(segment.text.utf8.count)
            text += segment.text
            switch segment.visibility {
            case .plain:
                break
            case .hidden:
                regions.append(VisibilityRegionTable.Region(utf8Offset: utf8Offset, utf8Length: utf8Length, conditionIndex: UInt32(hiddenSegmentCount % 2)))
                hiddenSegmentCount += 1
            case .shownByItsCondition:
                regions.append(VisibilityRegionTable.Region(utf8Offset: utf8Offset, utf8Length: utf8Length, conditionIndex: 2))
            }
        }
        return RuntimeInterfaceCorpusEntry(
            object: RuntimeObject(name: "Fixture", displayName: "Fixture", kind: .swift(.type(.struct)), imagePath: "/images/Fixture", children: []),
            interface: SemanticString { Standard(text) }.frozen(),
            visibilityRegions: VisibilityRegionTable(regions: regions, conditions: conditions),
            members: []
        )
    }

    private static func projectedText(of entry: RuntimeInterfaceCorpusEntry) -> String {
        entry.projection(under: visibility)?.text.text ?? entry.interface.text
    }

    private static func hasHit(of pattern: RuntimeInterfaceTextMatcher.Pattern, in text: String) throws -> Bool {
        var budget = RuntimeInterfaceTextMatcher.RegularExpressionBudget()
        return try !RuntimeInterfaceTextMatcher.hits(in: text, pattern: pattern, budget: &budget).isEmpty
    }

    @Test("an entry is skipped only when its projection has no hit", arguments: [
        PrefilterCase(
            segments: [.plain("let foo, "), .hidden("bar, "), .plain("baz")],
            query: "foo, baz", matchMode: .containing,
            projectedText: "let foo, baz", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a hit running across a seam"
        ),
        PrefilterCase(
            segments: [.plain("foo"), .hidden("Bar"), .plain(" = 1")],
            query: "foo", matchMode: .matchingWord,
            projectedText: "foo = 1", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a word that ends at a seam once the identifier after it is taken out"
        ),
        PrefilterCase(
            segments: [.hidden("a_"), .plain("foo = 1")],
            query: "foo", matchMode: .startingWith,
            projectedText: "foo = 1", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a word that starts the text once what came before it is taken out"
        ),
        PrefilterCase(
            segments: [.plain("let x = foo"), .hidden("Bar")],
            query: "foo", matchMode: .endingWith,
            projectedText: "let x = foo", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a word that ends the text once what came after it is taken out"
        ),
        PrefilterCase(
            segments: [.plain("fo"), .hidden("XX"), .plain("o"), .hidden("YY"), .plain("bar")],
            query: "foobar", matchMode: .containing,
            projectedText: "foobar", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a hit running across two seams"
        ),
        PrefilterCase(
            segments: [.plain("foo"), .hidden("XX"), .hidden("YY"), .plain("bar")],
            query: "foobar", matchMode: .containing,
            projectedText: "foobar", mayHaveHits: true, projectionHasHit: true,
            testDescription: "two hidden regions that touch make one seam"
        ),
        PrefilterCase(
            segments: [.plain("FO"), .hidden("x"), .plain("O = 1")],
            query: "foo", matchMode: .containing,
            projectedText: "FOO = 1", mayHaveHits: true, projectionHasHit: true,
            testDescription: "case folding across a seam"
        ),
        PrefilterCase(
            segments: [.plain("FO"), .hidden("x"), .plain("O = 1")],
            query: "foo", matchMode: .containing, isCaseSensitive: true,
            projectedText: "FOO = 1", mayHaveHits: false, projectionHasHit: false,
            testDescription: "no case folding across a seam when the search is case-sensitive"
        ),
        PrefilterCase(
            segments: [.plain("foo"), .hidden("Bar"), .plain("baz")],
            query: "foo", matchMode: .matchingWord,
            projectedText: "foobaz", mayHaveHits: false, projectionHasHit: false,
            testDescription: "the byte after a seam changes but is still an identifier byte"
        ),
        PrefilterCase(
            segments: [.plain("é"), .hidden("x"), .plain("foo")],
            query: "foo", matchMode: .startingWith,
            projectedText: "éfoo", mayHaveHits: false, projectionHasHit: false,
            testDescription: "a non-ASCII byte before a seam is an identifier byte"
        ),
        PrefilterCase(
            segments: [.plain("let x"), .hidden(" // needle")],
            query: "needle", matchMode: .containing,
            projectedText: "let x", mayHaveHits: true, projectionHasHit: false,
            testDescription: "a hit of the hidden text alone still gets the projection"
        ),
        PrefilterCase(
            segments: [.plain("foo"), .hidden(" "), .plain("bar")],
            query: "foo", matchMode: .matchingWord,
            projectedText: "foobar", mayHaveHits: true, projectionHasHit: false,
            testDescription: "a word of the full text that the projection joins to the next one"
        ),
        PrefilterCase(
            segments: [.plain("foo"), .shownByItsCondition("XX"), .plain("bar")],
            query: "foobar", matchMode: .containing,
            projectedText: "fooXXbar", mayHaveHits: false, projectionHasHit: false,
            testDescription: "a region its condition shows makes no seam"
        ),
        PrefilterCase(
            segments: [.plain("0123456789abc"), .hidden("X"), .plain("def")],
            query: "abcdef", matchMode: .containing,
            projectedText: "0123456789abcdef", mayHaveHits: true, projectionHasHit: true,
            testDescription: "more kept bytes before a seam than the needle is long"
        ),
        PrefilterCase(
            segments: [.plain("ab"), .hidden("X"), .plain("c"), .hidden("Y"), .plain("d")],
            query: "abcd", matchMode: .matchingWord,
            projectedText: "abcd", mayHaveHits: true, projectionHasHit: true,
            testDescription: "the kept bytes around a seam reach past a nearer hidden region"
        ),
        PrefilterCase(
            segments: [.plain("ab"), .hidden("X"), .plain("abab")],
            query: "abab", matchMode: .startingWith,
            projectedText: "ababab", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a needle that overlaps itself across a seam"
        ),
        PrefilterCase(
            segments: [.plain("let foo, "), .hidden("bar, "), .plain("baz")],
            query: "qux", matchMode: .containing,
            projectedText: "let foo, baz", mayHaveHits: false, projectionHasHit: false,
            testDescription: "a word on neither side of any seam"
        ),
        PrefilterCase(
            segments: [.plain("foo"), .hidden("Bar")],
            query: "fo+", matchMode: .regularExpression,
            projectedText: "foo", mayHaveHits: true, projectionHasHit: true,
            testDescription: "a regular expression always gets the projection"
        ),
    ])
    func prefilterCases(_ testCase: PrefilterCase) throws {
        let entry = Self.entry(testCase.segments)
        let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: testCase.query, matchMode: testCase.matchMode, isCaseSensitive: testCase.isCaseSensitive)
        let projectedText = Self.projectedText(of: entry)

        #expect(projectedText == testCase.projectedText)
        #expect(entry.mayHaveHits(of: pattern, under: Self.visibility) == testCase.mayHaveHits)
        #expect(try Self.hasHit(of: pattern, in: projectedText) == testCase.projectionHasHit)
    }

    /// SplitMix64 with a fixed seed: the same texts on every run.
    struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64

        init(seed: UInt64) {
            state = seed
        }

        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var value = state
            value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
            value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
            return value ^ (value >> 31)
        }
    }

    /// Identifier bytes, separators, an upper-case letter and a two-byte
    /// letter: enough to put every kind of boundary on every side of a seam.
    private static let pieces = ["a", "b", "A", "_", " ", "é"]

    private static func randomText(pieceCountRange: ClosedRange<Int>, using generator: inout SeededGenerator) -> String {
        let pieceCount = Int.random(in: pieceCountRange, using: &generator)
        return (0 ..< pieceCount).map { _ in pieces[Int.random(in: 0 ..< pieces.count, using: &generator)] }.joined()
    }

    @Test("no entry whose projection has a hit is ever skipped", arguments: [
        (RuntimeInterfaceSearchMatchMode.containing, UInt64(1)),
        (RuntimeInterfaceSearchMatchMode.matchingWord, UInt64(2)),
        (RuntimeInterfaceSearchMatchMode.startingWith, UInt64(3)),
        (RuntimeInterfaceSearchMatchMode.endingWith, UInt64(4)),
    ])
    func prefilterNeverSkipsAHit(matchMode: RuntimeInterfaceSearchMatchMode, seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed)
        var skippedEntryCount = 0
        var keptEntryWithoutHitCount = 0
        for _ in 0 ..< 3000 {
            var segments: [Segment] = []
            for _ in 0 ..< Int.random(in: 1 ... 6, using: &generator) {
                let text = Self.randomText(pieceCountRange: 1 ... 3, using: &generator)
                switch Int.random(in: 0 ..< 3, using: &generator) {
                case 0: segments.append(.plain(text))
                case 1: segments.append(.hidden(text))
                default: segments.append(.shownByItsCondition(text))
                }
            }
            let entry = Self.entry(segments)
            let projectedText = Self.projectedText(of: entry)
            let query = Self.randomText(pieceCountRange: 1 ... 3, using: &generator)
            for isCaseSensitive in [false, true] {
                let pattern = try RuntimeInterfaceTextMatcher.Pattern(text: query, matchMode: matchMode, isCaseSensitive: isCaseSensitive)
                let projectionHasHit = try Self.hasHit(of: pattern, in: projectedText)
                let mayHaveHits = entry.mayHaveHits(of: pattern, under: Self.visibility)
                if projectionHasHit, !mayHaveHits {
                    Issue.record("skipped \(segments) for \"\(query)\" (case-sensitive: \(isCaseSensitive)) although \"\(projectedText)\" has a hit")
                }
                if !mayHaveHits {
                    skippedEntryCount += 1
                } else if !projectionHasHit {
                    keptEntryWithoutHitCount += 1
                }
            }
        }
        // Proves something only if it skipped entries, and shows how often
        // the shortcut answers yes for nothing.
        #expect(skippedEntryCount > 1000, "skipped \(skippedEntryCount), kept \(keptEntryWithoutHitCount) without a hit")
    }
}
