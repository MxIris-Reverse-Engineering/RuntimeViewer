import Foundation
import Testing
@testable import RuntimeViewerCore

/// A regular expression bounded the way a literal query is: the Find navigator sends a query with
/// find patterns among its text as a regular expression, and its match style has to keep meaning
/// what it means for plain text — the engine's identifier boundaries, not ICU's `\b`.
@Suite("RuntimeTextPattern boundaries")
struct RuntimeTextPatternBoundaryTests {
    /// Words next to every kind of neighbour the boundaries tell apart: identifier characters,
    /// `$` and `_`, punctuation, line ends, and characters outside ASCII on either side.
    private static let haystacks = [
        "@property NSView *view;\n- (void)View;\nNSViewController *viewController;",
        "setDelegate: _delegate delegate delegateQueue $delegate delegate$ delegate2 (delegate)",
        "tableView:didSelectRowAtIndexPath: didSelect -didSelect",
        "café cafe caféine écafé",
        "中文View View中文 😀View View😀 View",
        "aaaa a-a a.a a$a a_a",
        "- (void)viewDidLoad; // view",
    ]

    /// Queries that start or end with an identifier character, with punctuation, with regular
    /// expression syntax that has to be escaped, and outside ASCII.
    private static let queries = ["View", "view", "delegate", "didSelect", "café", "a", "aa", "a.a", "-", "(void)", "$delegate", "View😀"]

    @Test("a literal query sent escaped and bounded finds what it finds as plain text", arguments: [
        RuntimeInterfaceSearchMatchMode.containing, .matchingWord, .startingWith, .endingWith,
    ])
    func boundedRegularExpressionFindsWhatTheLiteralQueryFinds(matchMode: RuntimeInterfaceSearchMatchMode) throws {
        for isCaseSensitive in [true, false] {
            for query in Self.queries {
                let literal = try RuntimeTextPattern(text: query, matchMode: matchMode, isCaseSensitive: isCaseSensitive)
                let boundedExpression = RuntimeTextPattern.regularExpression(NSRegularExpression.escapedPattern(for: query), boundedAs: matchMode)
                let bounded = try RuntimeTextPattern(text: boundedExpression, matchMode: .regularExpression, isCaseSensitive: isCaseSensitive)
                for haystack in Self.haystacks {
                    #expect(
                        bounded.ranges(in: haystack) == literal.ranges(in: haystack),
                        "“\(query)” in “\(haystack)”, \(matchMode), case-sensitive \(isCaseSensitive)"
                    )
                }
            }
        }
    }

    @Test("the character class holds exactly the engine's identifier characters")
    func characterClassHoldsTheIdentifierCharacters() throws {
        let expression = try NSRegularExpression(pattern: "^\(RuntimeInterfaceTextMatcher.identifierCharacterClass)$")
        func isMatched(_ character: String) -> Bool {
            expression.firstMatch(in: character, range: NSRange(location: 0, length: (character as NSString).length)) != nil
        }
        for byte in UInt8(0) ..< 0x80 {
            #expect(isMatched(String(UnicodeScalar(byte))) == RuntimeInterfaceTextMatcher.isIdentifierByte(byte), "byte \(byte)")
        }
        for character in ["\u{80}", "é", "中", "😀"] {
            #expect(isMatched(character), "“\(character)” is encoded in non-ASCII bytes alone")
        }
    }

    @Test("bounding adds no capture group and leaves containing and regular expressions alone")
    func boundingKeepsTheGroupsAndTheUnboundedStyles() throws {
        let expression = #"(\d+)-(?:\1)"#
        #expect(RuntimeTextPattern.regularExpression(expression, boundedAs: .containing) == expression)
        #expect(RuntimeTextPattern.regularExpression(expression, boundedAs: .regularExpression) == expression)
        let bounded = RuntimeTextPattern.regularExpression(expression, boundedAs: .matchingWord)
        #expect(try NSRegularExpression(pattern: bounded).numberOfCaptureGroups == 1)

        let pattern = try RuntimeTextPattern(text: bounded, matchMode: .regularExpression, isCaseSensitive: true)
        let text = "12-12 a12-12 12-12b (12-12) 12-13"
        let matched = pattern.ranges(in: text).map { (text as NSString).substring(with: $0) }
        #expect(matched == ["12-12", "12-12"])
        #expect(pattern.ranges(in: text).map(\.location) == [0, 21])
    }

    @Test("an alternation stays inside the boundaries")
    func alternationStaysInsideTheBoundaries() throws {
        let bounded = RuntimeTextPattern.regularExpression("view|window", boundedAs: .startingWith)
        let pattern = try RuntimeTextPattern(text: bounded, matchMode: .regularExpression, isCaseSensitive: true)
        let text = "subview viewDidLoad newwindow windowController"
        #expect(pattern.ranges(in: text).map { (text as NSString).substring(with: $0) } == ["view", "window"])
    }
}
