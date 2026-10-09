import Foundation
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

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
}

extension NSRange {
    fileprivate func withLength(_ length: Int) -> NSRange {
        NSRange(location: location, length: length)
    }
}
