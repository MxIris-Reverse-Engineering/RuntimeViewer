import Foundation
import Testing
import RuntimeViewerCore

/// The public face of the engine's matching rules, which the app uses to find a hit again in
/// the text it shows: the same match styles, case folding and boundaries as a search.
@Suite("RuntimeTextPattern")
struct RuntimeTextPatternTests {
    private static let text = "@property NSView *view;\n- (void)View;"

    private static func substrings(of ranges: [NSRange], in text: String) -> [String] {
        ranges.map { (text as NSString).substring(with: $0) }
    }

    @Test("a whole word is not found inside a longer one")
    func matchingWordKeepsToIdentifierBoundaries() throws {
        let pattern = try RuntimeTextPattern(text: "View", matchMode: .matchingWord, isCaseSensitive: true)
        let ranges = pattern.ranges(in: Self.text)
        #expect(ranges == [NSRange(location: (Self.text as NSString).range(of: "View;").location, length: 4)])
    }

    @Test("an insensitive search folds ASCII case only, as the engine does")
    func insensitiveSearchFoldsASCIICase() throws {
        let pattern = try RuntimeTextPattern(text: "view", matchMode: .containing, isCaseSensitive: false)
        #expect(Self.substrings(of: pattern.ranges(in: Self.text), in: Self.text) == ["View", "view", "View"])
    }

    @Test("a regular expression anchors at lines, and its ranges are UTF-16")
    func regularExpressionAnchorsAtLines() throws {
        let text = "é first\n- (void)second;"
        let pattern = try RuntimeTextPattern(text: #"^- \(void\)(\w+)"#, matchMode: .regularExpression, isCaseSensitive: true)
        let ranges = pattern.ranges(in: text)
        #expect(Self.substrings(of: ranges, in: text) == ["- (void)second"])
        #expect(ranges.first?.location == ("é first\n" as NSString).length)
    }

    @Test("an empty query and an invalid regular expression do not compile")
    func invalidPatternsThrow() {
        #expect(throws: (any Error).self) { try RuntimeTextPattern(text: "", matchMode: .containing, isCaseSensitive: true) }
        #expect(throws: (any Error).self) { try RuntimeTextPattern(text: "(", matchMode: .regularExpression, isCaseSensitive: true) }
    }
}
