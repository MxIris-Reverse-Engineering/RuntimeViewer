import Foundation
import RuntimeViewerCore

/// What the Find navigator hands the content pane along with a navigation:
/// where in the object's interface the hit is, so the pane can scroll there
/// and flash it once the interface is on screen.
///
/// The corpus and the pane print the same object, but the corpus prints
/// with every annotation on while the pane prints with the user's display
/// options, so the line number alone is not enough. The pane locates the hit
/// in its own text in this order (proposal `draft-find-navigator` §4):
///
/// 1. a line equal to `lineText`, the one nearest `lineNumber` when several
///    are, with `matchRangeInLine` applied inside it;
/// 2. failing that, `query` searched the same way the navigator did, the
///    hit nearest `lineNumber`;
/// 3. failing that, nothing — the pane stays at the top of the object.
public struct ContentHighlightRequest: Hashable, Sendable {
    /// 1-based line in the corpus interface.
    public let lineNumber: Int
    /// The hit's line as the corpus printed it (possibly windowed), or the
    /// member's declaration text.
    public let lineText: String
    /// Where the hit sits inside `lineText`, when the request comes from a
    /// text search.
    public let matchRangeInLine: RuntimeTextRange?
    /// The text to fall back to when `lineText` is not on screen: the query
    /// of a text search, the member name of a member search.
    public let query: String
    public let isCaseSensitive: Bool

    public init(lineNumber: Int, lineText: String, matchRangeInLine: RuntimeTextRange?, query: String, isCaseSensitive: Bool) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeInLine = matchRangeInLine
        self.query = query
        self.isCaseSensitive = isCaseSensitive
    }

    /// The UTF-16 range in `displayedText` this request resolves to, by the
    /// priority order above, or `nil` when nothing on screen carries it.
    ///
    /// Pure so the content pipeline can run it off the main scheduler.
    public func locate(in displayedText: String) -> NSRange? {
        let lines = Self.lines(of: displayedText)
        guard !lines.isEmpty else { return nil }
        let targetLineIndex = max(0, lineNumber - 1)
        let normalizedLineText = Self.normalized(lineText)

        // 1. Whole-line match, nearest to the corpus line number.
        if !normalizedLineText.isEmpty {
            var bestLine: Line?
            for line in lines where Self.normalized(line.text) == normalizedLineText {
                if bestLine == nil || abs(line.index - targetLineIndex) < abs(bestLine!.index - targetLineIndex) {
                    bestLine = line
                }
            }
            if let bestLine {
                return rangeInsideLine(bestLine, of: displayedText)
            }
        }

        // 2. The query itself, nearest to the corpus line number.
        guard !query.isEmpty else { return nil }
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        var bestRange: NSRange?
        var bestDistance = Int.max
        for line in lines {
            guard let found = line.text.range(of: query, options: options) else { continue }
            let distance = abs(line.index - targetLineIndex)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            let location = line.utf16Offset + line.text.utf16.distance(from: line.text.startIndex, to: found.lowerBound)
            let length = line.text.utf16.distance(from: found.lowerBound, to: found.upperBound)
            bestRange = NSRange(location: location, length: length)
        }
        return bestRange
    }

    private struct Line {
        let index: Int
        let text: String
        /// UTF-16 offset of the line's first character in the whole text.
        let utf16Offset: Int
    }

    private static func lines(of text: String) -> [Line] {
        var lines: [Line] = []
        var utf16Offset = 0
        var index = 0
        text.enumerateLines { lineText, _ in
            lines.append(Line(index: index, text: lineText, utf16Offset: utf16Offset))
            utf16Offset += lineText.utf16.count + 1
            index += 1
        }
        return lines
    }

    /// Lines compare with their indentation and the navigator's ellipsis
    /// window trimmed, so a hit on an indented member still matches its
    /// windowed corpus line.
    private static func normalized(_ line: String) -> String {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("…") { trimmed.removeFirst() }
        if trimmed.hasSuffix("…") { trimmed.removeLast() }
        return trimmed
    }

    private func rangeInsideLine(_ line: Line, of displayedText: String) -> NSRange {
        let leadingWhitespaceCount = line.text.utf16.distance(
            from: line.text.startIndex,
            to: line.text.firstIndex { !$0.isWhitespace } ?? line.text.endIndex
        )
        let lineStart = line.utf16Offset + leadingWhitespaceCount
        let lineContentLength = line.text.utf16.count - leadingWhitespaceCount
        // The corpus line was normalized the same way, so the range is
        // relative to its first non-blank character (after any ellipsis).
        let corpusLeadingCount = lineText.utf16.distance(
            from: lineText.startIndex,
            to: lineText.firstIndex { !$0.isWhitespace } ?? lineText.endIndex
        ) + (lineText.trimmingCharacters(in: .whitespaces).hasPrefix("…") ? 1 : 0)
        if let matchRangeInLine {
            let location = matchRangeInLine.location - corpusLeadingCount
            if location >= 0, location + matchRangeInLine.length <= lineContentLength {
                return NSRange(location: lineStart + location, length: matchRangeInLine.length)
            }
        }
        let options: String.CompareOptions = isCaseSensitive ? [] : [.caseInsensitive]
        if !query.isEmpty, let found = line.text.range(of: query, options: options) {
            let location = line.text.utf16.distance(from: line.text.startIndex, to: found.lowerBound)
            let length = line.text.utf16.distance(from: found.lowerBound, to: found.upperBound)
            return NSRange(location: line.utf16Offset + location, length: length)
        }
        return NSRange(location: lineStart, length: lineContentLength)
    }
}
