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
}
