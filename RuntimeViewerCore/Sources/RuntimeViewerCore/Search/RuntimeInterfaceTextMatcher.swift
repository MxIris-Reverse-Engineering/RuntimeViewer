import Foundation
import Semantic

/// Text matching over one frozen interface, and over member names.
///
/// Pure functions over `FrozenSemanticString`: no actor, no state, so the
/// matching rules — the four match styles, case folding, word boundaries,
/// the scope → semantic-kind mapping, line numbering and the windowed line
/// text — can be tested on hand-built strings without an engine. Member
/// searches run the same rules over names.
///
/// Offsets are UTF-8 bytes throughout the scan, because that is how the
/// frozen text is stored and how its spans are measured; only the range
/// handed out in a match is UTF-16, for the app side.
enum RuntimeInterfaceTextMatcher {
    /// A hit in the text: UTF-8 offset and byte length.
    struct Hit: Hashable {
        let utf8Offset: Int
        let utf8Length: Int
    }

    enum PatternError: Swift.Error {
        case emptyQuery
        case invalidRegularExpression(String)
    }

    /// The query compiled once per search, not once per interface. Text and
    /// member searches compile theirs the same way, so a match style means
    /// the same thing in an interface and in a member's name.
    struct Pattern: Sendable {
        let matchMode: RuntimeInterfaceSearchMatchMode
        let isCaseSensitive: Bool
        /// Which parts of an interface a hit may land in. A member's name has
        /// no parts, so member searches leave it at `.all`.
        let scope: RuntimeInterfaceSearchScope
        /// Query bytes, ASCII case-folded when the search is insensitive.
        let needle: [UInt8]
        /// `NSRegularExpression` rather than Swift `Regex`: the engine's
        /// deployment target predates the latter.
        let regex: NSRegularExpression?

        init(text: String, matchMode: RuntimeInterfaceSearchMatchMode, isCaseSensitive: Bool, scope: RuntimeInterfaceSearchScope = .all) throws {
            self.matchMode = matchMode
            self.isCaseSensitive = isCaseSensitive
            self.scope = scope
            guard !text.isEmpty else { throw PatternError.emptyQuery }
            if matchMode == .regularExpression {
                do {
                    self.regex = try NSRegularExpression(pattern: text, options: isCaseSensitive ? [] : [.caseInsensitive])
                } catch {
                    throw PatternError.invalidRegularExpression("\(error)")
                }
                self.needle = []
            } else {
                self.regex = nil
                let bytes = Array(text.utf8)
                self.needle = isCaseSensitive ? bytes : bytes.map(Self.asciiLowercased)
            }
        }

        init(_ query: RuntimeInterfaceSearchQuery) throws {
            try self.init(text: query.text, matchMode: query.matchMode, isCaseSensitive: query.isCaseSensitive, scope: query.scope)
        }

        static func asciiLowercased(_ byte: UInt8) -> UInt8 {
            (UInt8(ascii: "A") ... UInt8(ascii: "Z")).contains(byte) ? byte + 32 : byte
        }
    }

    /// Lines with more UTF-16 units than this are windowed around the hit.
    static let lineTextWindowLength = 320

    /// How many units of the line are kept ahead of a windowed hit.
    static let lineTextWindowLeadingLength = 100

    // MARK: - Hits

    /// Every hit of `pattern` in `text`, non-overlapping, in offset order.
    /// Word boundaries use the identifier character class `[A-Za-z0-9_$]`;
    /// any non-ASCII byte counts as an identifier character, so a boundary
    /// never falls inside a multi-byte scalar.
    static func hits(in text: String, pattern: Pattern) -> [Hit] {
        if let regex = pattern.regex {
            return regexHits(in: text, regex: regex)
        }
        return literalHits(in: text, pattern: pattern)
    }

    private static func regexHits(in text: String, regex: NSRegularExpression) -> [Hit] {
        var result: [Hit] = []
        let wholeRange = NSRange(location: 0, length: text.utf16.count)
        for match in regex.matches(in: text, options: [], range: wholeRange) {
            guard match.range.length > 0, let range = Range(match.range, in: text) else { continue }
            let offset = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
            let length = text.utf8.distance(from: range.lowerBound, to: range.upperBound)
            guard length > 0 else { continue }
            result.append(Hit(utf8Offset: offset, utf8Length: length))
        }
        return result
    }

    private static func literalHits(in text: String, pattern: Pattern) -> [Hit] {
        let needle = pattern.needle
        guard !needle.isEmpty else { return [] }
        let isCaseSensitive = pattern.isCaseSensitive
        let matchMode = pattern.matchMode
        var text = text
        return text.withUTF8 { haystack -> [Hit] in
            var result: [Hit] = []
            let haystackCount = haystack.count
            let needleCount = needle.count
            guard haystackCount >= needleCount else { return result }
            let firstNeedleByte = needle[0]
            var index = 0
            let lastStart = haystackCount - needleCount
            while index <= lastStart {
                let candidate = isCaseSensitive ? haystack[index] : Pattern.asciiLowercased(haystack[index])
                guard candidate == firstNeedleByte else {
                    index += 1
                    continue
                }
                var matchedCount = 1
                while matchedCount < needleCount {
                    let byte = haystack[index + matchedCount]
                    let folded = isCaseSensitive ? byte : Pattern.asciiLowercased(byte)
                    guard folded == needle[matchedCount] else { break }
                    matchedCount += 1
                }
                guard matchedCount == needleCount,
                      boundariesSatisfied(in: haystack, start: index, length: needleCount, matchMode: matchMode)
                else {
                    index += 1
                    continue
                }
                result.append(Hit(utf8Offset: index, utf8Length: needleCount))
                index += needleCount
            }
            return result
        }
    }

    private static func boundariesSatisfied(in haystack: UnsafeBufferPointer<UInt8>, start: Int, length: Int, matchMode: RuntimeInterfaceSearchMatchMode) -> Bool {
        let startsWord = start == 0 || !isIdentifierByte(haystack[start - 1])
        let endsWord = start + length == haystack.count || !isIdentifierByte(haystack[start + length])
        switch matchMode {
        case .containing, .regularExpression: return true
        case .startingWith: return startsWord
        case .endingWith: return endsWord
        case .matchingWord: return startsWord && endsWord
        }
    }

    static func isIdentifierByte(_ byte: UInt8) -> Bool {
        switch byte {
        case UInt8(ascii: "A") ... UInt8(ascii: "Z"),
             UInt8(ascii: "a") ... UInt8(ascii: "z"),
             UInt8(ascii: "0") ... UInt8(ascii: "9"),
             UInt8(ascii: "_"), UInt8(ascii: "$"):
            return true
        default:
            return byte >= 0x80
        }
    }

    // MARK: - Matches

    /// Runs `pattern` over `interface` and reports every hit inside the
    /// query's scope to `collect`, in offset order, until `collect` returns
    /// `false`. Hits are still counted after that, so the return value is the
    /// true number of in-scope hits whether or not they were all collected.
    /// A hit that starts inside one of `excludedUTF8Ranges` — ascending,
    /// non-overlapping — is neither reported nor counted.
    @discardableResult
    static func matches(
        in interface: FrozenSemanticString,
        object: RuntimeObject,
        pattern: Pattern,
        excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>] = [],
        collect: (RuntimeInterfaceSearchMatch) -> Bool
    ) -> Int {
        let hits = hits(in: interface.text, pattern: pattern)
        guard !hits.isEmpty else { return 0 }

        let layout = Layout(interface)
        var count = 0
        var isCollecting = true
        var excludedRangeIndex = 0
        for hit in hits {
            while excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].upperBound <= hit.utf8Offset {
                excludedRangeIndex += 1
            }
            if excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].contains(hit.utf8Offset) {
                continue
            }
            let kind = layout.semanticKind(atUTF8Offset: hit.utf8Offset)
            guard pattern.scope.includes(kind) else { continue }
            count += 1
            guard isCollecting else { continue }
            let match = makeMatch(for: hit, kind: kind, in: layout, object: object)
            isCollecting = collect(match)
        }
        return count
    }

    /// Line starts and span starts of one interface, built once per scan.
    struct Layout {
        let text: String
        /// UTF-8 offsets at which lines begin; the first is always 0.
        let lineStartOffsets: [Int]
        /// UTF-8 offset at which each span begins, plus a trailing sentinel.
        let spanStartOffsets: [Int]
        let spanKinds: [RuntimeSemanticKind]

        init(_ interface: FrozenSemanticString) {
            self.text = interface.text
            var lineStartOffsets = [0]
            var text = interface.text
            text.withUTF8 { bytes in
                for (index, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
                    lineStartOffsets.append(index + 1)
                }
            }
            self.lineStartOffsets = lineStartOffsets

            var spanStartOffsets: [Int] = []
            spanStartOffsets.reserveCapacity(interface.spans.count + 1)
            var spanKinds: [RuntimeSemanticKind] = []
            spanKinds.reserveCapacity(interface.spans.count)
            var offset = 0
            for span in interface.spans {
                spanStartOffsets.append(offset)
                spanKinds.append(RuntimeSemanticKind(SemanticType(frozenTypeCode: span.typeCode) ?? .other))
                offset += Int(span.length)
            }
            spanStartOffsets.append(offset)
            self.spanStartOffsets = spanStartOffsets
            self.spanKinds = spanKinds
        }

        /// 0-based index of the line containing the byte at `offset`.
        func lineIndex(containingUTF8Offset offset: Int) -> Int {
            // Last line start that is <= offset.
            var low = 0
            var high = lineStartOffsets.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStartOffsets[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return low
        }

        func semanticKind(atUTF8Offset offset: Int) -> RuntimeSemanticKind {
            guard !spanKinds.isEmpty else { return .other }
            var low = 0
            var high = spanKinds.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if spanStartOffsets[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return spanKinds[low]
        }

        /// UTF-8 range of line `lineIndex`, without its terminator.
        func lineUTF8Range(at lineIndex: Int) -> Range<Int> {
            let start = lineStartOffsets[lineIndex]
            let end: Int
            if lineIndex + 1 < lineStartOffsets.count {
                end = lineStartOffsets[lineIndex + 1] - 1
            } else {
                end = text.utf8.count
            }
            return start ..< max(start, end)
        }
    }

    private static func makeMatch(for hit: Hit, kind: RuntimeSemanticKind, in layout: Layout, object: RuntimeObject) -> RuntimeInterfaceSearchMatch {
        let text = layout.text
        let lineIndex = layout.lineIndex(containingUTF8Offset: hit.utf8Offset)
        let lineRange = layout.lineUTF8Range(at: lineIndex)
        let utf8 = text.utf8
        let lineStartIndex = utf8.index(text.startIndex, offsetBy: lineRange.lowerBound)
        let lineEndIndex = utf8.index(text.startIndex, offsetBy: lineRange.upperBound)
        let hitStartIndex = utf8.index(text.startIndex, offsetBy: hit.utf8Offset)
        // A regular expression can match across a line break; the range is
        // clamped to the hit's own line so the row can still highlight it.
        let hitEndOffset = min(hit.utf8Offset + hit.utf8Length, lineRange.upperBound)
        let hitEndIndex = utf8.index(text.startIndex, offsetBy: max(hitEndOffset, hit.utf8Offset))

        let line = String(text[lineStartIndex ..< lineEndIndex])
        let location = text.utf16.distance(from: lineStartIndex, to: hitStartIndex)
        let length = text.utf16.distance(from: hitStartIndex, to: hitEndIndex)
        let (lineText, rangeInLine) = windowed(line: line, location: location, length: length)

        return RuntimeInterfaceSearchMatch(
            object: object,
            lineNumber: lineIndex + 1,
            lineText: lineText,
            matchRangeInLine: rangeInLine,
            semanticKind: kind
        )
    }

    /// Keeps the whole line when it is short; otherwise a window of
    /// `lineTextWindowLength` UTF-16 units that starts
    /// `lineTextWindowLeadingLength` units before the hit, marked with an
    /// ellipsis at each cut edge. The returned range is relative to the
    /// returned text.
    static func windowed(line: String, location: Int, length: Int) -> (text: String, range: RuntimeTextRange) {
        let utf16 = line.utf16
        let lineLength = utf16.count
        guard lineLength > lineTextWindowLength else {
            return (line, RuntimeTextRange(location: location, length: length))
        }
        let windowStart = max(0, min(location - lineTextWindowLeadingLength, lineLength - lineTextWindowLength))
        let windowEnd = min(lineLength, windowStart + lineTextWindowLength)
        let startIndex = utf16.index(line.startIndex, offsetBy: windowStart)
        let endIndex = utf16.index(line.startIndex, offsetBy: windowEnd)
        var text = String(line[startIndex ..< endIndex])
        var adjustedLocation = location - windowStart
        if windowStart > 0 {
            text = "…" + text
            adjustedLocation += 1
        }
        if windowEnd < lineLength {
            text += "…"
        }
        let adjustedLength = min(length, max(0, (text.utf16.count - (windowEnd < lineLength ? 1 : 0)) - adjustedLocation))
        return (text, RuntimeTextRange(location: adjustedLocation, length: adjustedLength))
    }

    // MARK: - Member names

    /// Where `pattern` first matches `name`, as a UTF-16 range, or `nil`.
    ///
    /// The rules are the text search's, unchanged: the same match styles, the
    /// same ASCII case folding, the same identifier boundaries. A member's
    /// name is matched as if it were a line of text, so each piece of a
    /// multi-part selector is a word of its own — `didSelect` starts
    /// `tableView:didSelectRowAtIndexPath:` — while `delegate` is no whole
    /// word of `setDelegate:` or `_delegate`.
    static func memberNameMatchRange(in name: String, pattern: Pattern) -> RuntimeTextRange? {
        guard let hit = hits(in: name, pattern: pattern).first else { return nil }
        let utf8 = name.utf8
        let startIndex = utf8.index(name.startIndex, offsetBy: hit.utf8Offset)
        let endIndex = utf8.index(startIndex, offsetBy: hit.utf8Length)
        return RuntimeTextRange(
            location: name.utf16.distance(from: name.startIndex, to: startIndex),
            length: name.utf16.distance(from: startIndex, to: endIndex)
        )
    }
}
