import Foundation
import Semantic

/// Text matching over one frozen interface, and over member and type names.
///
/// Pure functions over `FrozenSemanticString`: no actor, no state, so the
/// matching rules — the four match styles, case folding, word boundaries,
/// the scope → semantic-kind mapping, line numbering and the windowed line
/// text — can be tested on hand-built strings without an engine. Member and
/// relationship searches run the same rules over names.
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

    /// Reads as a sentence on every path an error travels: the Find navigator
    /// and the XPC transport show `localizedDescription`, while the socket
    /// transports send `"\(error)"` across — so `description` says the same.
    enum PatternError: LocalizedError, CustomStringConvertible, Equatable {
        case emptyQuery
        /// `reason` is Foundation's own account of what is wrong, kept for the
        /// log; the reader is shown the pattern instead.
        case invalidRegularExpression(pattern: String, reason: String)
        /// The search's `RegularExpressionBudget` is spent.
        case regularExpressionTooExpensive(pattern: String)

        var errorDescription: String? {
            switch self {
            case .emptyQuery:
                "Type something to search for."
            case .invalidRegularExpression(let pattern, _):
                "“\(pattern)” is not a valid regular expression."
            case .regularExpressionTooExpensive(let pattern):
                "“\(pattern)” takes too long to match. Nested repetition such as (\\w+)+ is the usual cause."
            }
        }

        var description: String {
            errorDescription ?? "The search pattern is not valid."
        }
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
        /// Whether the regular expression engine reports progress while it
        /// matches, so a match can be stopped from inside: only for a
        /// pattern with a quantified group, the only kind that can backtrack
        /// exponentially (`hasQuantifiedGroup(_:)`). Reporting costs a call
        /// for every position the scan advances to, which more than triples
        /// the time of an ordinary pattern over a corpus.
        let reportsProgressWhileMatching: Bool

        init(text: String, matchMode: RuntimeInterfaceSearchMatchMode, isCaseSensitive: Bool, scope: RuntimeInterfaceSearchScope = .all) throws {
            self.matchMode = matchMode
            self.isCaseSensitive = isCaseSensitive
            self.scope = scope
            guard !text.isEmpty else { throw PatternError.emptyQuery }
            if matchMode == .regularExpression {
                do {
                    // `^` and `$` anchor at line boundaries, as in Xcode's Find: an
                    // entry is a whole multi-line interface while a hit is reported
                    // on its line. Member and type names are one line, so for them
                    // nothing changes.
                    var options: NSRegularExpression.Options = [.anchorsMatchLines]
                    if !isCaseSensitive {
                        options.insert(.caseInsensitive)
                    }
                    self.regex = try NSRegularExpression(pattern: text, options: options)
                } catch {
                    throw PatternError.invalidRegularExpression(pattern: text, reason: error.localizedDescription)
                }
                self.reportsProgressWhileMatching = RuntimeInterfaceTextMatcher.hasQuantifiedGroup(text)
                self.needle = []
            } else {
                self.regex = nil
                self.reportsProgressWhileMatching = false
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

    /// How long one search may spend inside the regular expression engine,
    /// summed over every call it makes there. A pattern that backtracks
    /// catastrophically — `(\w+)+\(` over a long identifier — never finishes
    /// a single match on its own; spending this is what stops it.
    ///
    /// A value each search makes afresh and passes through every call, so
    /// `Pattern` stays a plain `Sendable` value. Literal match styles run in
    /// linear time and spend nothing.
    struct RegularExpressionBudget: Sendable {
        static let defaultTimeLimit: TimeInterval = 10

        private(set) var remainingNanoseconds: UInt64

        init(timeLimit: TimeInterval = Self.defaultTimeLimit) {
            // Capped well below `UInt64.max`, so a deadline computed from it
            // cannot overflow.
            let maximumNanoseconds = Double(UInt64.max / 4)
            remainingNanoseconds = UInt64(min(max(0, timeLimit) * 1_000_000_000, maximumNanoseconds))
        }

        var isExhausted: Bool {
            remainingNanoseconds == 0
        }

        mutating func spend(_ nanoseconds: UInt64) {
            remainingNanoseconds -= min(nanoseconds, remainingNanoseconds)
        }
    }

    /// How many calls of the enumeration block pass between two looks at
    /// the task's cancellation and the clock. With `.reportProgress` the
    /// block runs for about every position the scan advances to — 5.9
    /// million calls over Foundation's corpus of 5.6 million UTF-16 units on
    /// macOS 26 — and inside one long match as well: a 20 ms budget stops
    /// `(a+)+\(` over 24 a's, which takes over a second to fail on its own,
    /// after about 22 ms. Without it the block runs once per match, so the
    /// checks happen every this many matches.
    private static let progressReportsPerCheck = 64

    /// Every hit of `pattern` in `text`, non-overlapping, in offset order.
    /// Word boundaries use the identifier character class `[A-Za-z0-9_$]`;
    /// any non-ASCII byte counts as an identifier character, so a boundary
    /// never falls inside a multi-byte scalar.
    ///
    /// A regular expression spends `budget` and throws
    /// `PatternError.regularExpressionTooExpensive` once it is gone, from
    /// inside a match that has not finished as well; it throws
    /// `CancellationError` as soon as the calling task is cancelled.
    static func hits(in text: String, pattern: Pattern, budget: inout RegularExpressionBudget) throws -> [Hit] {
        if let regularExpression = pattern.regex {
            return try regularExpressionHits(in: text, regularExpression: regularExpression, reportsProgressWhileMatching: pattern.reportsProgressWhileMatching, budget: &budget)
        }
        return literalHits(in: text, pattern: pattern)
    }

    private static func regularExpressionHits(in text: String, regularExpression: NSRegularExpression, reportsProgressWhileMatching: Bool, budget: inout RegularExpressionBudget) throws -> [Hit] {
        guard !budget.isExhausted else {
            throw PatternError.regularExpressionTooExpensive(pattern: regularExpression.pattern)
        }
        var result: [Hit] = []
        let wholeRange = NSRange(location: 0, length: text.utf16.count)
        let startTime = DispatchTime.now().uptimeNanoseconds
        let deadline = startTime + budget.remainingNanoseconds
        var progressReportCount = 0
        var isCancelled = false
        var isOverBudget = false
        // `.reportProgress` has the engine call back during one long match
        // too, so setting `stop` ends a match that would otherwise never
        // finish. A pattern that cannot backtrack exponentially is stopped
        // between matches, and between calls once the budget is spent.
        // `DispatchTime` because `ContinuousClock` needs macOS 13.
        let options: NSRegularExpression.MatchingOptions = reportsProgressWhileMatching ? [.reportProgress] : []
        regularExpression.enumerateMatches(in: text, options: options, range: wholeRange) { match, _, stop in
            if let match, match.range.length > 0, let range = Range(match.range, in: text) {
                let offset = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
                let length = text.utf8.distance(from: range.lowerBound, to: range.upperBound)
                if length > 0 {
                    result.append(Hit(utf8Offset: offset, utf8Length: length))
                }
            }
            progressReportCount += 1
            guard progressReportCount % Self.progressReportsPerCheck == 0 else { return }
            if Task.isCancelled {
                isCancelled = true
                stop.pointee = true
            } else if DispatchTime.now().uptimeNanoseconds >= deadline {
                isOverBudget = true
                stop.pointee = true
            }
        }
        budget.spend(DispatchTime.now().uptimeNanoseconds - startTime)
        if isCancelled {
            throw CancellationError()
        }
        if isOverBudget {
            throw PatternError.regularExpressionTooExpensive(pattern: regularExpression.pattern)
        }
        return result
    }

    /// Whether a quantifier applies to a group of `pattern` — `(a+)+`,
    /// `(?:ab)*`, `(x|y){2,}`, `(x)?` — which exponential backtracking needs:
    /// without one, a failing match chooses among a fixed number of
    /// quantifiers, never among the ways of splitting a run into repetitions
    /// of a group. Escapes, `\Q…\E` quotes and character sets — nested ones
    /// included — are not groups. Errs towards yes: in free-spacing mode a
    /// quantifier can stand apart from its group, so a pattern that turns it
    /// on counts as having one.
    static func hasQuantifiedGroup(_ pattern: String) -> Bool {
        let scalars = Array(pattern.unicodeScalars)
        var index = 0
        var characterSetDepth = 0
        var isQuoted = false
        while index < scalars.count {
            let scalar = scalars[index]
            let nextScalar = index + 1 < scalars.count ? scalars[index + 1] : nil
            if isQuoted {
                if scalar == "\\", nextScalar == "E" {
                    isQuoted = false
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            if scalar == "\\" {
                if nextScalar == "Q" {
                    isQuoted = true
                }
                // An escaped character is a literal, whatever it is.
                index += 2
                continue
            }
            if characterSetDepth > 0 {
                // A set can hold sets of its own: `[[a-z]--[aeiou]]`.
                if scalar == "[" {
                    characterSetDepth += 1
                } else if scalar == "]" {
                    characterSetDepth -= 1
                }
                index += 1
                continue
            }
            switch scalar {
            case "[":
                characterSetDepth = 1
            case "(" where nextScalar == "?":
                // Inline flags, `(?x)` or `(?ix:…)`, and their run of letters.
                var flagIndex = index + 2
                while flagIndex < scalars.count, Self.isInlineFlagScalar(scalars[flagIndex]) {
                    if scalars[flagIndex] == "x" {
                        return true
                    }
                    flagIndex += 1
                }
            case ")":
                if let nextScalar, "*+?{".unicodeScalars.contains(nextScalar) {
                    return true
                }
            default:
                break
            }
            index += 1
        }
        return false
    }

    /// A letter or the `-` of an inline flag group such as `(?i-x)`.
    private static func isInlineFlagScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a" ... "z").contains(scalar) || ("A" ... "Z").contains(scalar) || scalar == "-"
    }

    private static func literalHits(in text: String, pattern: Pattern) -> [Hit] {
        var text = text
        return text.withUTF8 { haystack in
            literalHits(inUTF8: haystack, pattern: pattern, stoppingAtFirstHit: false)
        }
    }

    /// `literalHits(in:pattern:)` over raw UTF-8 bytes, the buffer's ends
    /// counting as the text's ends; with `stoppingAtFirstHit`, at most the
    /// first hit.
    private static func literalHits(inUTF8 haystack: UnsafeBufferPointer<UInt8>, pattern: Pattern, stoppingAtFirstHit: Bool) -> [Hit] {
        pattern.needle.withUnsafeBufferPointer { needle -> [Hit] in
            var result: [Hit] = []
            let needleCount = needle.count
            guard needleCount > 0, haystack.count >= needleCount else { return result }
            let isCaseSensitive = pattern.isCaseSensitive
            let matchMode = pattern.matchMode
            let firstNeedleByte = needle[0]
            var index = 0
            let lastStart = haystack.count - needleCount
            while index <= lastStart {
                let candidate = isCaseSensitive ? haystack[index] : Pattern.asciiLowercased(haystack[index])
                guard candidate == firstNeedleByte,
                      isLiteralHit(in: haystack, at: index, needle: needle, isCaseSensitive: isCaseSensitive, matchMode: matchMode)
                else {
                    index += 1
                    continue
                }
                result.append(Hit(utf8Offset: index, utf8Length: needleCount))
                if stoppingAtFirstHit {
                    break
                }
                index += needleCount
            }
            return result
        }
    }

    /// Whether `needle` — case-folded already when the search is
    /// insensitive — starts at `index` of `haystack`, word boundaries
    /// included. The buffer's ends count as the text's ends.
    @inline(__always)
    private static func isLiteralHit(in haystack: UnsafeBufferPointer<UInt8>, at index: Int, needle: UnsafeBufferPointer<UInt8>, isCaseSensitive: Bool, matchMode: RuntimeInterfaceSearchMatchMode) -> Bool {
        guard index >= 0, index + needle.count <= haystack.count else { return false }
        for needleOffset in 0 ..< needle.count {
            let byte = haystack[index + needleOffset]
            let folded = isCaseSensitive ? byte : Pattern.asciiLowercased(byte)
            guard folded == needle[needleOffset] else { return false }
        }
        return boundariesSatisfied(in: haystack, start: index, length: needle.count, matchMode: matchMode)
    }

    /// Whether the literal `pattern` can hit what `text` becomes once
    /// `hiddenUTF8Ranges` — ascending, disjoint, none touching another — are
    /// taken out of it, decided without building that text. Never says no
    /// for a text with a hit; it may say yes for one with none. A regular
    /// expression can match across any length, so for one the answer is
    /// always yes.
    ///
    /// A hit of the shortened text either lies inside one stretch the cut
    /// left whole, with the bytes on either side of it unchanged — then it is
    /// a hit of `text` itself — or it touches a seam, where hidden bytes were
    /// taken out: it runs across the seam, or begins or ends right at it, so
    /// the byte its word boundary depends on changed. So any hit of `text`
    /// answers yes, and otherwise every start from a needle's length before
    /// each seam up to the seam is tried on the kept bytes around it — every
    /// start, not a greedy scan, which could take an overlapping start that
    /// misses the seam and step over the one that crosses it. The kept bytes
    /// reach one past the needle on each side, so the word boundary of every
    /// start is read from the bytes the shortened text really has there, or
    /// from its true ends.
    static func literalPattern(_ pattern: Pattern, mayHitTextOf text: String, hidingUTF8Ranges hiddenUTF8Ranges: [Range<Int>]) -> Bool {
        guard pattern.regex == nil else { return true }
        let needleCount = pattern.needle.count
        guard needleCount > 0 else { return false }
        var text = text
        return text.withUTF8 { bytes in
            if !literalHits(inUTF8: bytes, pattern: pattern, stoppingAtFirstHit: true).isEmpty {
                return true
            }
            return pattern.needle.withUnsafeBufferPointer { needle in
                let isCaseSensitive = pattern.isCaseSensitive
                // Every start tried at a seam covers the kept byte right
                // before the seam or the one right after it, so a seam with
                // neither among the needle's bytes needs no window — the
                // common case, a comment taken out between a declaration's
                // `;` and its line break.
                var isNeedleByte = [Bool](repeating: false, count: 256)
                for byte in needle {
                    isNeedleByte[Int(byte)] = true
                }
                func mayBeNeedleByte(at position: Int) -> Bool {
                    guard position >= 0, position < bytes.count else { return false }
                    let byte = bytes[position]
                    return isNeedleByte[Int(isCaseSensitive ? byte : Pattern.asciiLowercased(byte))]
                }
                var keptBytesBefore: [UInt8] = []
                keptBytesBefore.reserveCapacity(needleCount + 1)
                var window: [UInt8] = []
                window.reserveCapacity(2 * needleCount + 2)
                for (seamIndex, hiddenRange) in hiddenUTF8Ranges.enumerated() {
                    // The ranges touch no other, so these two bytes are kept.
                    guard mayBeNeedleByte(at: hiddenRange.lowerBound - 1) || mayBeNeedleByte(at: hiddenRange.upperBound) else { continue }
                    // The kept bytes before the seam, nearest first, skipping
                    // the hidden ranges closer than that.
                    keptBytesBefore.removeAll(keepingCapacity: true)
                    var position = hiddenRange.lowerBound
                    var earlierRangeIndex = seamIndex - 1
                    while keptBytesBefore.count <= needleCount, position > 0 {
                        position -= 1
                        if earlierRangeIndex >= 0, hiddenUTF8Ranges[earlierRangeIndex].contains(position) {
                            position = hiddenUTF8Ranges[earlierRangeIndex].lowerBound
                            earlierRangeIndex -= 1
                            continue
                        }
                        keptBytesBefore.append(bytes[position])
                    }
                    window.removeAll(keepingCapacity: true)
                    window.append(contentsOf: keptBytesBefore.reversed())
                    let seamOffset = window.count
                    position = hiddenRange.upperBound
                    var laterRangeIndex = seamIndex + 1
                    while window.count - seamOffset <= needleCount, position < bytes.count {
                        if laterRangeIndex < hiddenUTF8Ranges.count, hiddenUTF8Ranges[laterRangeIndex].contains(position) {
                            position = hiddenUTF8Ranges[laterRangeIndex].upperBound
                            laterRangeIndex += 1
                            continue
                        }
                        window.append(bytes[position])
                        position += 1
                    }
                    let touchesSeam = window.withUnsafeBufferPointer { windowBytes in
                        (max(0, seamOffset - needleCount) ... seamOffset).contains { start in
                            isLiteralHit(in: windowBytes, at: start, needle: needle, isCaseSensitive: isCaseSensitive, matchMode: pattern.matchMode)
                        }
                    }
                    if touchesSeam {
                        return true
                    }
                }
                return false
            }
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
    /// non-overlapping — is neither reported nor counted. A regular
    /// expression spends `budget`; see `hits(in:pattern:budget:)`.
    ///
    /// `isCollecting` false asks for the count alone, as a search past its
    /// result limit does. A count needs no line table, and over every kind no
    /// span table either: each table is built for the first hit that needs
    /// it, the span kinds for a hit whose kind decides something, the lines
    /// for a hit collected.
    @discardableResult
    static func matches(
        in interface: FrozenSemanticString,
        object: RuntimeObject,
        pattern: Pattern,
        budget: inout RegularExpressionBudget,
        excludingUTF8Ranges excludedUTF8Ranges: [Range<Int>] = [],
        isCollecting isCollectingAtStart: Bool = true,
        collect: (RuntimeInterfaceSearchMatch) -> Bool
    ) throws -> Int {
        let hits = try hits(in: interface.text, pattern: pattern, budget: &budget)
        guard !hits.isEmpty else { return 0 }

        var spanKindTable: SpanKindTable?
        var lineTable: RuntimeInterfaceLineTable?
        var count = 0
        var isCollecting = isCollectingAtStart
        var excludedRangeIndex = 0
        for hit in hits {
            while excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].upperBound <= hit.utf8Offset {
                excludedRangeIndex += 1
            }
            if excludedRangeIndex < excludedUTF8Ranges.count, excludedUTF8Ranges[excludedRangeIndex].contains(hit.utf8Offset) {
                continue
            }
            let kind: RuntimeSemanticKind
            if !isCollecting, pattern.scope == .all {
                // Counted and never shown: its kind decides nothing.
                kind = .other
            } else {
                let entrySpanKindTable: SpanKindTable
                if let spanKindTable {
                    entrySpanKindTable = spanKindTable
                } else {
                    entrySpanKindTable = SpanKindTable(interface)
                    spanKindTable = entrySpanKindTable
                    RuntimeInterfaceSearchWorkLog.record(.spanKindTable)
                }
                kind = entrySpanKindTable.semanticKind(atUTF8Offset: hit.utf8Offset)
            }
            guard pattern.scope.includes(kind) else { continue }
            count += 1
            guard isCollecting else { continue }
            let entryLineTable: RuntimeInterfaceLineTable
            if let lineTable {
                entryLineTable = lineTable
            } else {
                entryLineTable = RuntimeInterfaceLineTable(interface.text)
                lineTable = entryLineTable
                RuntimeInterfaceSearchWorkLog.record(.lineTable)
            }
            let match = makeMatch(for: hit, kind: kind, in: interface.text, lineTable: entryLineTable, object: object)
            isCollecting = collect(match)
        }
        return count
    }

    /// The semantic kind of every span of one interface, looked up by UTF-8
    /// offset: all a count over a scope needs.
    struct SpanKindTable {
        /// UTF-8 offset at which each span begins, plus a trailing sentinel.
        let spanStartOffsets: [Int]
        let spanKinds: [RuntimeSemanticKind]

        init(_ interface: FrozenSemanticString) {
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

        func semanticKind(atUTF8Offset offset: Int) -> RuntimeSemanticKind {
            guard !spanKinds.isEmpty else { return .other }
            var lowerBound = 0
            var upperBound = spanKinds.count - 1
            while lowerBound < upperBound {
                let middle = (lowerBound + upperBound + 1) / 2
                if spanStartOffsets[middle] <= offset {
                    lowerBound = middle
                } else {
                    upperBound = middle - 1
                }
            }
            return spanKinds[lowerBound]
        }
    }

    private static func makeMatch(for hit: Hit, kind: RuntimeSemanticKind, in text: String, lineTable: RuntimeInterfaceLineTable, object: RuntimeObject) -> RuntimeInterfaceSearchMatch {
        let lineIndex = lineTable.lineIndex(containingUTF8Offset: hit.utf8Offset)
        let lineRange = lineTable.lineUTF8Range(at: lineIndex)
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
    static func memberNameMatchRange(in name: String, pattern: Pattern, budget: inout RegularExpressionBudget) throws -> RuntimeTextRange? {
        guard let hit = try hits(in: name, pattern: pattern, budget: &budget).first else { return nil }
        let utf8 = name.utf8
        let startIndex = utf8.index(name.startIndex, offsetBy: hit.utf8Offset)
        let endIndex = utf8.index(startIndex, offsetBy: hit.utf8Length)
        return RuntimeTextRange(
            location: name.utf16.distance(from: name.startIndex, to: startIndex),
            length: name.utf16.distance(from: startIndex, to: endIndex)
        )
    }

    // MARK: - Type names

    /// Whether `pattern` matches the type named `qualifiedName`.
    ///
    /// The rules are the text search's, as for member names, run over the
    /// type's own name: the last component of its qualified name, without
    /// generic arguments — `View` for `SwiftUI.View`, `Array` for
    /// `Swift.Array<Swift.Int>`. That anchors the match styles where Xcode's
    /// type hierarchy queries anchor them, at the ends of the symbol's own
    /// name (`-[IDEBatchFindQuerySpecification
    /// termSymbolsForWorkspace:useQualifiedNameParser:cancelWhen:]`):
    /// `Starting With View` finds `ViewBuilder` and not `NSView`, and a module
    /// or an enclosing type matches nothing by itself. A query with a dot in
    /// it names what the type is in, so it runs over the whole qualified name
    /// instead; so does a regular expression, which anchors itself where it
    /// means to.
    static func typeNameMatches(_ qualifiedName: String, pattern: Pattern, budget: inout RegularExpressionBudget) throws -> Bool {
        let matchesQualifiedName = pattern.regex != nil || pattern.needle.contains(UInt8(ascii: "."))
        let name = matchesQualifiedName ? qualifiedName : String(ownTypeName(of: qualifiedName))
        return try !hits(in: name, pattern: pattern, budget: &budget).isEmpty
    }

    /// The last component of a qualified type name, without its generic
    /// arguments: `Storage` for `SwiftUI.Text.Storage`, `Array` for
    /// `Swift.Array<Swift.Int>`. A dot inside angle brackets or parentheses —
    /// a generic argument's module, a private type's discriminator — splits
    /// nothing, and the arrow of a function type closes no bracket.
    static func ownTypeName(of qualifiedName: String) -> Substring {
        let utf8 = qualifiedName.utf8
        var depth = 0
        var componentStart = utf8.startIndex
        var genericArgumentsStart: String.Index?
        var previousByte: UInt8 = 0
        for index in utf8.indices {
            let byte = utf8[index]
            switch byte {
            case UInt8(ascii: "<"):
                if depth == 0, genericArgumentsStart == nil {
                    genericArgumentsStart = index
                }
                depth += 1
            case UInt8(ascii: "("), UInt8(ascii: "["):
                depth += 1
            case UInt8(ascii: ">") where previousByte == UInt8(ascii: "-"):
                break
            case UInt8(ascii: ">"), UInt8(ascii: ")"), UInt8(ascii: "]"):
                depth = max(0, depth - 1)
            case UInt8(ascii: ".") where depth == 0:
                componentStart = utf8.index(after: index)
                genericArgumentsStart = nil
            default:
                break
            }
            previousByte = byte
        }
        return qualifiedName[componentStart ..< (genericArgumentsStart ?? utf8.endIndex)]
    }
}
