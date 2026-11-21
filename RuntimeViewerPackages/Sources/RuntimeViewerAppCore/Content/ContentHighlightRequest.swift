import Foundation
import RuntimeViewerCore

/// What the Find navigator hands the content pane along with a navigation:
/// where in the object's interface the hit is, so the pane can scroll there
/// and flash it once the interface is on screen.
///
/// The corpus and the pane print the same object, but the corpus prints
/// with every annotation on while the pane prints with the user's display
/// options, so the line number alone is not enough. The pane locates the hit
/// in its own text in this order (proposal `0029-find-navigator` §4):
///
/// 1. a line equal to `lineText`, the one nearest `lineNumber` when several
///    are, with `matchRangeInLine` applied inside it — or, when `lineText` is
///    a window the engine cut out of a long line, a line containing it, with
///    the hit at the same place inside the window — or, when no line equals
///    it, consecutive lines that spell it once whitespace is left out: a
///    corpus line Break Long Types laid out over several lines on screen
///    (proposal `multiline-type-formatting`), with the hit on the same
///    characters;
/// 2. failing that, `query` matched the way the search matched it — its
///    `matchMode`, ASCII case folding, identifier boundaries, regular
///    expressions — the hit nearest `lineNumber`;
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
    /// of a text search — the pattern itself for a regular expression — or
    /// the member name of a member search.
    public let query: String
    /// How `query` matches, as the search that found the hit matched it.
    public let matchMode: RuntimeInterfaceSearchMatchMode
    public let isCaseSensitive: Bool
    /// Whether the pane also shows `query` in its find bar, with every match
    /// in the object marked: a text search's hit, whose other matches are
    /// worth seeing next to it. A member search or a cross reference names a
    /// single declaration and only reveals that one.
    public let showsQueryInFindBar: Bool

    public init(lineNumber: Int, lineText: String, matchRangeInLine: RuntimeTextRange?, query: String, matchMode: RuntimeInterfaceSearchMatchMode = .containing, isCaseSensitive: Bool, showsQueryInFindBar: Bool = false) {
        self.lineNumber = lineNumber
        self.lineText = lineText
        self.matchRangeInLine = matchRangeInLine
        self.query = query
        self.matchMode = matchMode
        self.isCaseSensitive = isCaseSensitive
        self.showsQueryInFindBar = showsQueryInFindBar
    }

    /// What the pane's find bar searches for, when `showsQueryInFindBar`
    /// asks for one.
    public var findBarQuery: ContentFindBarQuery? {
        guard showsQueryInFindBar, !query.isEmpty else { return nil }
        return ContentFindBarQuery(text: query, matchMode: matchMode, isCaseSensitive: isCaseSensitive)
    }

    /// The UTF-16 range in `displayedText` this request resolves to, by the
    /// priority order above, or `nil` when nothing on screen carries it.
    ///
    /// Pure so the content pipeline can run it off the main scheduler.
    public func locate(in displayedText: String) -> NSRange? {
        let lines = Self.lines(of: displayedText)
        guard !lines.isEmpty else { return nil }
        let targetLineIndex = max(0, lineNumber - 1)
        let pattern = query.isEmpty ? nil : try? RuntimeTextPattern(text: query, matchMode: matchMode, isCaseSensitive: isCaseSensitive)

        // 1. The corpus line, nearest to the corpus line number.
        if let window = Self.window(of: lineText) {
            // A long line reached the navigator as a window cut around the hit; the line on
            // screen contains the window, and the hit sits at the same place inside it.
            if let range = locateWindow(window, in: lines, nearLineIndex: targetLineIndex) {
                return range
            }
            // The line was broken over several lines on screen: the window spells part of them
            // once whitespace is left out of both.
            if let range = locateBrokenWindow(window, in: lines, of: displayedText, nearLineIndex: targetLineIndex) {
                return range
            }
        } else {
            let normalizedLineText = Self.normalized(lineText)
            if !normalizedLineText.isEmpty {
                var bestLine: Line?
                for line in lines where Self.normalized(line.text) == normalizedLineText {
                    if bestLine == nil || abs(line.index - targetLineIndex) < abs(bestLine!.index - targetLineIndex) {
                        bestLine = line
                    }
                }
                if let bestLine {
                    return rangeInsideLine(bestLine, pattern: pattern)
                }
                // Broken over several lines on screen: only whitespace was added, so whole lines
                // spell the corpus line once it is left out of both.
                if let range = locateBrokenLine(in: lines, of: displayedText, nearLineIndex: targetLineIndex, pattern: pattern) {
                    return range
                }
            }
        }

        // 2. The query, matched as the search matched it, nearest to the corpus line number.
        // Matched over the whole text in one pass, so a regular expression spends one time
        // budget, not one per line; `^` and `$` anchor at lines, as in the search.
        guard let pattern else { return nil }
        var bestRange: NSRange?
        var bestDistance = Int.max
        var lineCursor = 0
        for found in pattern.ranges(in: displayedText) {
            while lineCursor + 1 < lines.count, lines[lineCursor + 1].utf16Offset <= found.location {
                lineCursor += 1
            }
            let distance = abs(lines[lineCursor].index - targetLineIndex)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            bestRange = found
        }
        return bestRange
    }

    /// The hit inside the line on screen that contains `window`, the line nearest
    /// `targetLineIndex` when several do; `nil` when no line contains it.
    private func locateWindow(_ window: (text: String, leadingMarkerLength: Int), in lines: [Line], nearLineIndex targetLineIndex: Int) -> NSRange? {
        guard !window.text.isEmpty, let matchRangeInLine else { return nil }
        let locationInWindow = matchRangeInLine.location - window.leadingMarkerLength
        guard locationInWindow >= 0, locationInWindow + matchRangeInLine.length <= window.text.utf16.count else { return nil }
        var bestRange: NSRange?
        var bestDistance = Int.max
        for line in lines {
            let windowRange = (line.text as NSString).range(of: window.text)
            guard windowRange.location != NSNotFound else { continue }
            let distance = abs(line.index - targetLineIndex)
            guard distance < bestDistance else { continue }
            bestDistance = distance
            bestRange = NSRange(location: line.utf16Offset + windowRange.location + locationInWindow, length: matchRangeInLine.length)
        }
        return bestRange
    }

    /// The text of a window the engine cut out of a long line, without the ellipsis that marks
    /// each cut edge, and the UTF-16 length of the leading mark; `nil` for a whole line.
    /// `RuntimeInterfaceTextMatcher.windowed` marks every edge it cuts, so a line with no mark
    /// at either end is whole.
    private static func window(of lineText: String) -> (text: String, leadingMarkerLength: Int)? {
        let marker = "…"
        let hasLeadingMarker = lineText.hasPrefix(marker)
        let hasTrailingMarker = lineText.hasSuffix(marker)
        guard hasLeadingMarker || hasTrailingMarker else { return nil }
        var text = Substring(lineText)
        if hasLeadingMarker {
            text = text.dropFirst()
        }
        if hasTrailingMarker, !text.isEmpty {
            text = text.dropLast()
        }
        return (String(text), hasLeadingMarker ? marker.utf16.count : 0)
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

    /// Lines compare with their indentation trimmed, so a hit on an indented
    /// member still matches its corpus line. A windowed corpus line never gets
    /// here: `locateWindow` looks for it instead.
    private static func normalized(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespaces)
    }

    private func rangeInsideLine(_ line: Line, pattern: RuntimeTextPattern?) -> NSRange {
        let leadingWhitespaceCount = line.text.utf16.distance(
            from: line.text.startIndex,
            to: line.text.firstIndex { !$0.isWhitespace } ?? line.text.endIndex
        )
        let lineStart = line.utf16Offset + leadingWhitespaceCount
        let lineContentLength = line.text.utf16.count - leadingWhitespaceCount
        // The corpus line was normalized the same way, so the range is
        // relative to its first non-blank character.
        let corpusLeadingCount = lineText.utf16.distance(
            from: lineText.startIndex,
            to: lineText.firstIndex { !$0.isWhitespace } ?? lineText.endIndex
        )
        if let matchRangeInLine {
            let location = matchRangeInLine.location - corpusLeadingCount
            if location >= 0, location + matchRangeInLine.length <= lineContentLength {
                return NSRange(location: lineStart + location, length: matchRangeInLine.length)
            }
        }
        if let found = pattern?.ranges(in: line.text).first {
            return NSRange(location: line.utf16Offset + found.location, length: found.length)
        }
        return NSRange(location: lineStart, length: lineContentLength)
    }

    // MARK: - A corpus line broken over several lines on screen

    /// A text without its whitespace — what Break Long Types adds: line breaks,
    /// indentation, and the space a broken `, ` loses — as UTF-16 code units,
    /// with the UTF-16 offset in the text of each unit kept.
    private struct CompactedText {
        var units: [UInt16] = []
        var originalOffsets: [Int] = []

        init(_ text: String) {
            var offset = 0
            for unit in text.utf16 {
                if !Self.isLayoutWhitespace(unit) {
                    units.append(unit)
                    originalOffsets.append(offset)
                }
                offset += 1
            }
        }

        private static func isLayoutWhitespace(_ unit: UInt16) -> Bool {
            Unicode.Scalar(unit)?.properties.isWhitespace ?? false
        }

        /// How many units kept come before the text's UTF-16 offset `offset`.
        func keptCount(before offset: Int) -> Int {
            var lowerBound = 0
            var upperBound = originalOffsets.count
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound) / 2
                if originalOffsets[middle] < offset {
                    lowerBound = middle + 1
                } else {
                    upperBound = middle
                }
            }
            return lowerBound
        }

        /// Where in `units` each occurrence of `other`'s units starts.
        func occurrences(of other: CompactedText) -> [Int] {
            guard let firstUnit = other.units.first, other.units.count <= units.count else { return [] }
            var starts: [Int] = []
            for start in 0 ... (units.count - other.units.count) where units[start] == firstUnit {
                if units[start ..< start + other.units.count].elementsEqual(other.units) {
                    starts.append(start)
                }
            }
            return starts
        }
    }

    /// The index into `lines` of the line holding `utf16Offset`.
    private static func lineIndex(holding utf16Offset: Int, in lines: [Line]) -> Int {
        var lowerBound = 0
        var upperBound = lines.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            if lines[middle].utf16Offset <= utf16Offset {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return max(0, lowerBound - 1)
    }

    /// The range in the displayed text from the `visibleStart`-th unit kept
    /// after `occurrenceStart` up to the end of the `visibleEnd - 1`-th: the
    /// same characters a range of the compacted corpus text covered.
    private static func displayedRange(of displayed: CompactedText, occurrenceStart: Int, visibleStart: Int, visibleEnd: Int) -> NSRange {
        let start = displayed.originalOffsets[occurrenceStart + visibleStart]
        guard visibleEnd > visibleStart else { return NSRange(location: start, length: 0) }
        let end = displayed.originalOffsets[occurrenceStart + visibleEnd - 1] + 1
        return NSRange(location: start, length: end - start)
    }

    /// The corpus line on screen as whole consecutive lines that spell it once
    /// whitespace is left out — the run starting nearest `targetLineIndex` —
    /// with the hit on the same characters; `nil` when no run does.
    private func locateBrokenLine(in lines: [Line], of displayedText: String, nearLineIndex targetLineIndex: Int, pattern: RuntimeTextPattern?) -> NSRange? {
        let corpusLine = CompactedText(lineText)
        guard !corpusLine.units.isEmpty else { return nil }
        let displayed = CompactedText(displayedText)
        var bestStart: Int?
        var bestDistance = Int.max
        for start in displayed.occurrences(of: corpusLine) {
            let firstLineIndex = Self.lineIndex(holding: displayed.originalOffsets[start], in: lines)
            let lastLineIndex = Self.lineIndex(holding: displayed.originalOffsets[start + corpusLine.units.count - 1], in: lines)
            // Whole lines only: nothing visible before the run on its first line, or after it on
            // its last.
            let startsTheLine = displayed.keptCount(before: lines[firstLineIndex].utf16Offset) == start
            let endOfLastLine = lines[lastLineIndex].utf16Offset + lines[lastLineIndex].text.utf16.count
            let endsTheLine = displayed.keptCount(before: endOfLastLine) == start + corpusLine.units.count
            guard startsTheLine, endsTheLine else { continue }
            let distance = abs(lines[firstLineIndex].index - targetLineIndex)
            if distance < bestDistance {
                bestDistance = distance
                bestStart = start
            }
        }
        guard let bestStart else { return nil }

        if let matchRangeInLine, matchRangeInLine.location >= 0, matchRangeInLine.location + matchRangeInLine.length <= lineText.utf16.count {
            let visibleStart = corpusLine.keptCount(before: matchRangeInLine.location)
            let visibleEnd = corpusLine.keptCount(before: matchRangeInLine.location + matchRangeInLine.length)
            if visibleStart < corpusLine.units.count {
                return Self.displayedRange(of: displayed, occurrenceStart: bestStart, visibleStart: visibleStart, visibleEnd: visibleEnd)
            }
        }
        let wholeRun = Self.displayedRange(of: displayed, occurrenceStart: bestStart, visibleStart: 0, visibleEnd: corpusLine.units.count)
        if let found = pattern?.ranges(in: (displayedText as NSString).substring(with: wholeRun)).first {
            return NSRange(location: wholeRun.location + found.location, length: found.length)
        }
        return wholeRun
    }

    /// The hit inside the lines on screen that spell `window` once whitespace
    /// is left out — the occurrence nearest `targetLineIndex` — at the same
    /// characters it sits on inside the window; `nil` when none does.
    private func locateBrokenWindow(_ window: (text: String, leadingMarkerLength: Int), in lines: [Line], of displayedText: String, nearLineIndex targetLineIndex: Int) -> NSRange? {
        guard !window.text.isEmpty, let matchRangeInLine else { return nil }
        let locationInWindow = matchRangeInLine.location - window.leadingMarkerLength
        guard locationInWindow >= 0, locationInWindow + matchRangeInLine.length <= window.text.utf16.count else { return nil }
        let compactWindow = CompactedText(window.text)
        guard !compactWindow.units.isEmpty else { return nil }
        let displayed = CompactedText(displayedText)
        var bestStart: Int?
        var bestDistance = Int.max
        for start in displayed.occurrences(of: compactWindow) {
            let distance = abs(lines[Self.lineIndex(holding: displayed.originalOffsets[start], in: lines)].index - targetLineIndex)
            if distance < bestDistance {
                bestDistance = distance
                bestStart = start
            }
        }
        guard let bestStart else { return nil }
        let visibleStart = compactWindow.keptCount(before: locationInWindow)
        let visibleEnd = compactWindow.keptCount(before: locationInWindow + matchRangeInLine.length)
        guard visibleStart < compactWindow.units.count else { return nil }
        return Self.displayedRange(of: displayed, occurrenceStart: bestStart, visibleStart: visibleStart, visibleEnd: visibleEnd)
    }
}
