import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore

/// The content pane's second-stage locate: a corpus line found in the text on
/// screen by the priority order of `ContentHighlightRequest.locate(in:)`.
@Suite("ContentHighlightRequest")
struct ContentHighlightRequestTests {
    private let displayedText = """
    @interface NSString : NSObject
    - (id)initWithFormat:(id)format;
    - (id)initWithFormat:(id)format locale:(id)locale;
    @end
    """

    private func utf16Range(of substring: String, in text: String, occurrence: Int = 0) -> NSRange {
        var searchRange = text.startIndex ..< text.endIndex
        var found: Range<String.Index>?
        for _ in 0 ... occurrence {
            found = text.range(of: substring, range: searchRange)
            guard let found else { break }
            searchRange = found.upperBound ..< text.endIndex
        }
        let range = found!
        return NSRange(
            location: text.utf16.distance(from: text.startIndex, to: range.lowerBound),
            length: text.utf16.distance(from: range.lowerBound, to: range.upperBound)
        )
    }

    @Test("a line equal to the corpus line is found, and the match range applied inside it")
    func wholeLineMatch() {
        let request = ContentHighlightRequest(
            lineNumber: 3,
            lineText: "- (id)initWithFormat:(id)format locale:(id)locale;",
            matchRangeInLine: RuntimeTextRange(location: 32, length: 7),
            query: "locale:",
            isCaseSensitive: true
        )
        let range = request.locate(in: displayedText)
        #expect(range == utf16Range(of: "locale:", in: displayedText))
    }

    @Test("indentation and the navigator's ellipsis window do not defeat a whole-line match")
    func normalizedLineMatch() {
        let indented = "    - (id)initWithFormat:(id)format;"
        let request = ContentHighlightRequest(
            lineNumber: 2,
            lineText: "…- (id)initWithFormat:(id)format;…",
            matchRangeInLine: RuntimeTextRange(location: 7, length: 14),
            query: "initWithFormat",
            isCaseSensitive: true
        )
        let range = request.locate(in: "@interface Foo\n" + indented + "\n@end")
        #expect(range == utf16Range(of: "initWithFormat", in: "@interface Foo\n" + indented + "\n@end"))
    }

    @Test("of several equal lines, the one nearest the corpus line number wins")
    func nearestLineWins() {
        let text = "x\nfoo\nbar\nfoo\nfoo\n"
        let request = ContentHighlightRequest(lineNumber: 4, lineText: "foo", matchRangeInLine: RuntimeTextRange(location: 0, length: 3), query: "foo", isCaseSensitive: true)
        let range = request.locate(in: text)
        #expect(range == NSRange(location: text.utf16.distance(from: text.startIndex, to: text.range(of: "foo", options: [], range: text.index(text.startIndex, offsetBy: 8) ..< text.endIndex)!.lowerBound), length: 3))
    }

    @Test("without the line on screen, the query is searched nearest the corpus line")
    func queryFallback() {
        let request = ContentHighlightRequest(
            lineNumber: 3,
            lineText: "// this line was printed with an annotation the pane hides",
            matchRangeInLine: nil,
            query: "initwithformat",
            isCaseSensitive: false
        )
        let range = request.locate(in: displayedText)
        // Two lines carry the query; line 3 is nearer to the requested line 3.
        #expect(range == utf16Range(of: "initWithFormat", in: displayedText, occurrence: 1))
    }

    @Test("nothing on screen carries the request")
    func miss() {
        let request = ContentHighlightRequest(lineNumber: 1, lineText: "gone", matchRangeInLine: nil, query: "absent", isCaseSensitive: false)
        #expect(request.locate(in: displayedText) == nil)
        #expect(request.locate(in: "") == nil)
    }

    // MARK: - Long lines

    /// A line longer than the navigator keeps whole: `SwiftUI.View` sits past column 320, after
    /// an earlier `View` inside another type's name.
    private static let longLine = "public func makeBody(effect: _BackgroundViewHoverEffect, "
        + String(repeating: "parameter: Swift.Int, ", count: 14)
        + "content: SwiftUI.View) -> some SwiftUI.View"
    private static let longLinePrefix = "struct Sample {\n    "
    private static let longLineText = longLinePrefix + longLine + "\n}"
    /// The hit: `View` in `content: SwiftUI.View`.
    private static let longLineHitRange = NSRange(location: (longLine as NSString).range(of: "content: SwiftUI.View").location + "content: SwiftUI.".utf16.count, length: 4)

    /// The window `RuntimeInterfaceTextMatcher.windowed` cuts around a hit in a line longer than
    /// 320 UTF-16 units: from 100 units ahead of the hit, 320 in all, each cut edge marked `…`.
    private static func window(of line: String, around hitRange: NSRange) -> (text: String, rangeInWindow: RuntimeTextRange) {
        let utf16 = Array(line.utf16)
        let windowStart = max(0, min(hitRange.location - 100, utf16.count - 320))
        let windowEnd = min(utf16.count, windowStart + 320)
        var text = String(decoding: utf16[windowStart ..< windowEnd], as: UTF16.self)
        var location = hitRange.location - windowStart
        if windowStart > 0 {
            text = "…" + text
            location += 1
        }
        if windowEnd < utf16.count {
            text += "…"
        }
        return (text, RuntimeTextRange(location: location, length: hitRange.length))
    }

    @Test("a regular-expression hit on a long line is found inside the window the navigator kept")
    func regularExpressionHitOnALongLine() {
        #expect(Self.longLine.utf16.count > 320)
        let window = Self.window(of: Self.longLine, around: Self.longLineHitRange)
        // How the Find page built a regular-expression request before the fix: no query to fall back to.
        let request = ContentHighlightRequest(lineNumber: 2, lineText: window.text, matchRangeInLine: window.rangeInWindow, query: "", isCaseSensitive: true)
        let expected = NSRange(location: Self.longLinePrefix.utf16.count + Self.longLineHitRange.location, length: 4)
        #expect(request.locate(in: Self.longLineText) == expected)
    }

    @Test("a literal hit on a long line is not taken by an earlier occurrence of the same text")
    func literalHitOnALongLine() {
        let window = Self.window(of: Self.longLine, around: Self.longLineHitRange)
        let request = ContentHighlightRequest(lineNumber: 2, lineText: window.text, matchRangeInLine: window.rangeInWindow, query: "View", isCaseSensitive: true)
        let expected = NSRange(location: Self.longLinePrefix.utf16.count + Self.longLineHitRange.location, length: 4)
        #expect(request.locate(in: Self.longLineText) == expected)
    }

    @Test("the fallback matches as the search did: a whole word is not found inside a longer one")
    func fallbackHonoursTheMatchStyle() {
        let text = "@interface Sample : NSObject\n@property (readonly) NSView *view;\n- (void)View;\n@end"
        let request = ContentHighlightRequest(lineNumber: 2, lineText: "a line the pane no longer shows", matchRangeInLine: nil, query: "View", matchMode: .matchingWord, isCaseSensitive: true)
        #expect(request.locate(in: text) == utf16Range(of: "View;", in: text).withLength(4))
    }

    @Test("a regular expression falls back to the pattern itself, matched as the search matched it")
    func regularExpressionFallback() {
        let request = ContentHighlightRequest(lineNumber: 3, lineText: "a line the pane no longer shows", matchRangeInLine: nil, query: #"locale:\(\w+\)"#, matchMode: .regularExpression, isCaseSensitive: true)
        #expect(request.locate(in: displayedText) == utf16Range(of: "locale:(id)", in: displayedText))
    }

    // MARK: - Break Long Types (proposal multiline-type-formatting)

    /// The corpus prints a declaration on one line; the pane, with Break Long Types on, lays its
    /// type out over several.
    private static let brokenCorpusLine = "    var nested: Pair<Pair<Swift.Int, Swift.String>, Swift.Double>"

    private static let brokenDeclaration = """
        var nested: Pair<
            Pair<
                Swift.Int,
                Swift.String
            >,
            Swift.Double
        >
    """

    private func corpusRange(of substring: String) -> RuntimeTextRange {
        let range = utf16Range(of: substring, in: Self.brokenCorpusLine)
        return RuntimeTextRange(location: range.location, length: range.length)
    }

    @Test("a corpus line broken over several lines on screen is located, the hit on the same characters")
    func aCorpusLineBrokenAcrossDisplayedLinesIsLocated() {
        let text = "struct Holder {\n" + Self.brokenDeclaration + "\n}"
        // No query to fall back to: only the broken line itself can place the hit.
        let request = ContentHighlightRequest(lineNumber: 2, lineText: Self.brokenCorpusLine, matchRangeInLine: corpusRange(of: "Swift.String"), query: "", isCaseSensitive: true)
        #expect(request.locate(in: text) == utf16Range(of: "Swift.String", in: text))
    }

    @Test("a hit across a break the formatting inserted covers the break")
    func aHitAcrossAnInsertedBreakCoversTheBreak() {
        let text = "struct Holder {\n" + Self.brokenDeclaration + "\n}"
        let request = ContentHighlightRequest(lineNumber: 2, lineText: Self.brokenCorpusLine, matchRangeInLine: corpusRange(of: "Swift.Int, Swift.String"), query: "Swift.Int, Swift.String", isCaseSensitive: true)
        let start = utf16Range(of: "Swift.Int", in: text).location
        let end = utf16Range(of: "Swift.String", in: text).upperBound
        #expect(request.locate(in: text) == NSRange(location: start, length: end - start))
    }

    @Test("of several broken occurrences, the one nearest the corpus line number wins")
    func theNearestBrokenOccurrenceWins() {
        let text = "struct First {\n" + Self.brokenDeclaration + "\n}\nstruct Second {\n" + Self.brokenDeclaration + "\n}"
        let request = ContentHighlightRequest(lineNumber: 12, lineText: Self.brokenCorpusLine, matchRangeInLine: corpusRange(of: "Swift.Double"), query: "", isCaseSensitive: true)
        #expect(request.locate(in: text) == utf16Range(of: "Swift.Double", in: text, occurrence: 1))
    }

    @Test("a line equal to the corpus line still wins over a broken occurrence nearer to it")
    func aWholeLineMatchStillWinsFirst() {
        let text = Self.brokenCorpusLine + "\nstruct Holder {\n" + Self.brokenDeclaration + "\n}"
        let request = ContentHighlightRequest(lineNumber: 4, lineText: Self.brokenCorpusLine, matchRangeInLine: corpusRange(of: "Swift.Double"), query: "Swift.Double", isCaseSensitive: true)
        #expect(request.locate(in: text) == utf16Range(of: "Swift.Double", in: text))
    }

    @Test("a run of characters inside a longer line is not taken for a corpus line")
    func aRunInsideALongerLineIsNotTakenForTheCorpusLine() {
        let text = "let value = Pair<Swift.Int,\n    Swift.String>"
        let request = ContentHighlightRequest(lineNumber: 1, lineText: "Swift.Int, Swift.String", matchRangeInLine: RuntimeTextRange(location: 0, length: 9), query: "", isCaseSensitive: true)
        #expect(request.locate(in: text) == nil)
    }

    @Test("a window of a long line the pane broke over several lines is located, the hit on the same characters")
    func aWindowOfABrokenLongLineIsLocated() {
        let arguments = (0 ..< 40).map { "Module.Argument\($0)" }
        let corpusLine = "    typealias Body = Module.Container<" + arguments.joined(separator: ", ") + ">"
        let displayedLines = ["    typealias Body = Module.Container<"] + arguments.dropLast().map { "        \($0)," } + ["        \(arguments.last!)", "    >"]
        let text = "extension Holder {\n" + displayedLines.joined(separator: "\n") + "\n}"
        let hitRange = (corpusLine as NSString).range(of: "Module.Argument30")
        #expect(corpusLine.utf16.count > 320)
        let window = Self.window(of: corpusLine, around: hitRange)
        let request = ContentHighlightRequest(lineNumber: 2, lineText: window.text, matchRangeInLine: window.rangeInWindow, query: "", isCaseSensitive: true)
        #expect(request.locate(in: text) == utf16Range(of: "Module.Argument30", in: text))
    }
}

extension NSRange {
    fileprivate func withLength(_ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }
}
