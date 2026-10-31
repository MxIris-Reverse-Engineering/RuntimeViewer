import Foundation
import RuntimeViewerCore
import Semantic

/// How the SourceEditor content pane draws the generated comments of one interface: what it
/// leaves out, which runs it colours, where it puts tags, and which rows collapse.
///
/// Built from the comment structure the engine sends with the interface, never from the comment
/// text: what a comment is and where its parts are comes from the printer that wrote it. What to
/// *do* with that is decided here, away from Xcode's frameworks, so it can be tested; the editor
/// bridge only carries it out. Ranges are UTF-16 ranges into the interface's text, the units the
/// editor and `NSString` count in.
///
/// The rules, by role: markers are left out — all but a continuation line's alignment spaces —
/// and so is the punctuation of separators — colons, brackets, commas, backticks, dashes, `#` —
/// down to one space; `=` and `..<` stay, since they say something. Tree prefixes keep their width but are not drawn, so a disclosure triangle can sit in
/// them. Labels, keys and qualifiers take the label colour, values the value colour, types and
/// names their own; prose keeps the comment colour.
public struct InterfaceCommentDecorations: Sendable, Equatable {
    public enum TagStyle: Sendable, Equatable {
        case standard
        /// An offset that could not be worked out, a member the image does not export, an
        /// address that does not resolve.
        case warning
        /// A sentence of explanation.
        case note
    }

    public enum RunStyle: Sendable, Equatable {
        case label
        case value
        case type
        case name
        /// Kept for its width but not drawn.
        case concealed
    }

    public struct Tag: Sendable, Equatable {
        public let range: NSRange
        public let style: TagStyle
    }

    public struct Run: Sendable, Equatable {
        public let range: NSRange
        public let style: RunStyle
    }

    /// A row that collapses: a field layout row with rows below it, or an enum case's header.
    public struct Collapsible: Sendable, Equatable {
        /// Where the disclosure triangle goes: columns that draw nothing of their own. Empty when
        /// the row has no such columns, which leaves the row without a triangle.
        public let disclosureRange: NSRange
        /// From the end of the row's line to the end of its last line.
        public let foldRange: NSRange
        public let startsCollapsed: Bool
    }

    public let tags: [Tag]
    public let runs: [Run]
    public let hiddenRanges: [NSRange]
    public let collapsibles: [Collapsible]

    public var isEmpty: Bool {
        tags.isEmpty && runs.isEmpty && hiddenRanges.isEmpty && collapsibles.isEmpty
    }

    public init(tags: [Tag], runs: [Run], hiddenRanges: [NSRange], collapsibles: [Collapsible]) {
        self.tags = tags
        self.runs = runs
        self.hiddenRanges = hiddenRanges
        self.collapsibles = collapsibles
    }

    /// The decorations of `interfaceString`'s comments as `structure` describes them. A comment or
    /// segment whose range does not fit the text — a structure from a different print — is left
    /// out rather than trusted.
    public init(structure: RuntimeInterfaceCommentStructure, interfaceString: FrozenSemanticString) {
        let text = interfaceString.string
        let textUnits = Array(text.utf16)
        let lines = Lines(textUnits: textUnits)

        var utf8Offsets: [Int] = []
        utf8Offsets.reserveCapacity((structure.comments.count + structure.segments.count) * 2)
        for comment in structure.comments {
            utf8Offsets.append(comment.utf8Range.lowerBound)
            utf8Offsets.append(comment.utf8Range.upperBound)
        }
        for segment in structure.segments {
            utf8Offsets.append(segment.utf8Range.lowerBound)
            utf8Offsets.append(segment.utf8Range.upperBound)
        }
        let utf16OffsetByUTF8Offset = Self.utf16Offsets(of: utf8Offsets, in: text)

        func utf16Range(of utf8Range: Range<Int>) -> Range<Int>? {
            guard let lower = utf16OffsetByUTF8Offset[utf8Range.lowerBound],
                  let upper = utf16OffsetByUTF8Offset[utf8Range.upperBound]
            else { return nil }
            return lower ..< upper
        }

        let commentRanges = structure.comments.map { utf16Range(of: $0.utf8Range) }
        var segmentsByComment = [[(role: RuntimeInterfaceCommentStructure.Role, range: Range<Int>)]](repeating: [], count: structure.comments.count)
        for segment in structure.segments {
            guard structure.comments.indices.contains(segment.commentIndex),
                  let range = utf16Range(of: segment.utf8Range),
                  !range.isEmpty,
                  lines.line(containing: range.lowerBound) == lines.line(containing: range.upperBound - 1)
            else { continue }
            segmentsByComment[segment.commentIndex].append((segment.role, range))
        }

        let errorRanges = Self.errorRanges(in: interfaceString)

        var tags: [Tag] = []
        var runs: [Run] = []
        var hiddenRanges: [NSRange] = []

        for (commentIndex, comment) in structure.comments.enumerated() {
            guard commentRanges[commentIndex] != nil else { continue }
            let segments = segmentsByComment[commentIndex]

            for segment in segments {
                switch segment.role {
                case .marker:
                    hiddenRanges.append(NSRange(Self.hiddenColumns(ofMarker: segment.range, in: textUnits)))
                case .separator:
                    hiddenRanges += Self.hiddenColumns(ofSeparator: segment.range, in: textUnits).map { NSRange($0) }
                case .treePrefix:
                    runs.append(Run(range: NSRange(segment.range), style: .concealed))
                case .label, .key, .qualifier:
                    runs.append(Run(range: NSRange(segment.range), style: .label))
                case .value:
                    runs.append(Run(range: NSRange(segment.range), style: .value))
                case .type:
                    runs.append(Run(range: NSRange(segment.range), style: .type))
                case .name:
                    runs.append(Run(range: NSRange(segment.range), style: .name))
                default:
                    break
                }
            }

            for group in Self.tagGroups(of: segments, kind: comment.kind, lines: lines) {
                let range = group.lowerBound ..< group.upperBound
                let containsError = errorRanges.contains { $0.overlaps(range) }
                tags.append(Tag(range: NSRange(range), style: containsError ? .warning : Self.tagStyle(of: comment.kind)))
            }
        }

        let collapsibles = Self.collapsibles(
            in: structure,
            commentRanges: commentRanges,
            segmentsByComment: segmentsByComment,
            lines: lines,
            textUnits: textUnits
        )

        self.init(tags: tags, runs: runs, hiddenRanges: hiddenRanges, collapsibles: collapsibles)
    }

    // MARK: - Tags

    private static let warningKinds: Set<RuntimeInterfaceCommentStructure.Kind> = [
        .fieldOffsetUnknown, .ivarOffsetUnknown, .exportStatus,
    ]

    /// Every kind a tag is drawn for in the standard style; the rest are notes.
    private static let standardKinds: Set<RuntimeInterfaceCommentStructure.Kind> = [
        .memberAddress, .vtableOffset, .pwtOffset, .fieldOffset, .fieldLayoutNode, .typeLayout,
        .typeLayoutElement, .enumLayoutSummary, .enumLayoutCaseHeader, .enumLayoutCaseEncoding,
        .enumLayoutCaseNote, .enumLayoutCaseFixedBytes, .enumLayoutCaseByte, .protocolExtensionDefault,
        .privateDeclarationSource, .conditionalWitness, .conditionalWitnessBranch,
        .strippedSymbolicRequirement, .impAddress, .ivarOffset, .propertySynthesis, .propertyDynamic,
        .typeNote,
    ]

    private static func tagStyle(of kind: RuntimeInterfaceCommentStructure.Kind) -> TagStyle {
        if warningKinds.contains(kind) { return .warning }
        if standardKinds.contains(kind) { return .standard }
        return .note
    }

    /// The kinds that list several facts, each of which gets a tag of its own.
    private static let kindsSplitAtKeys: Set<RuntimeInterfaceCommentStructure.Kind> = [
        .typeLayout, .typeLayoutElement, .enumLayoutSummary, .strippedSymbolicRequirement,
    ]

    /// The runs a comment's tags cover, line by line. A tag never crosses a line, and prose stays
    /// outside tags unless prose is all a line has.
    private static func tagGroups(
        of segments: [(role: RuntimeInterfaceCommentStructure.Role, range: Range<Int>)],
        kind: RuntimeInterfaceCommentStructure.Kind,
        lines: Lines
    ) -> [Range<Int>] {
        let contentRoles: Set<RuntimeInterfaceCommentStructure.Role> = [.label, .qualifier, .key, .value, .name, .type, .text]
        let content = segments.filter { contentRoles.contains($0.role) }
        let contentByLine = Dictionary(grouping: content) { lines.line(containing: $0.range.lowerBound) }

        var groups: [Range<Int>] = []
        for line in contentByLine.keys.sorted() {
            let lineSegments = contentByLine[line]!.sorted { $0.range.lowerBound < $1.range.lowerBound }
            var lineGroups: [[(role: RuntimeInterfaceCommentStructure.Role, range: Range<Int>)]] = []

            let isProseKind = tagStyle(of: kind) == .note
            if isProseKind || lineSegments.allSatisfy({ $0.role == .text }) {
                lineGroups = [lineSegments]
            } else if kind == .fieldLayoutNode {
                lineGroups = lineSegments.filter { $0.role == .value }.map { [$0] }
            } else if kind == .enumLayoutCaseByte {
                // `offset 0x08 = 0x01`; the binary that follows stays outside.
                if let firstValue = lineSegments.firstIndex(where: { $0.role == .value }) {
                    lineGroups = [Array(lineSegments[...firstValue])]
                } else {
                    lineGroups = [lineSegments]
                }
            } else {
                let withoutProse = lineSegments.filter { $0.role != .text }
                for segment in withoutProse {
                    let startsGroup: Bool
                    if kindsSplitAtKeys.contains(kind) {
                        startsGroup = segment.role == .key
                    } else if kind == .enumLayoutCaseHeader {
                        startsGroup = segment.role == .name || segment.role == .key
                    } else {
                        startsGroup = false
                    }
                    if startsGroup || lineGroups.isEmpty {
                        lineGroups.append([segment])
                    } else {
                        lineGroups[lineGroups.count - 1].append(segment)
                    }
                }
            }

            for group in lineGroups {
                guard let first = group.first, let last = group.last else { continue }
                groups.append(first.range.lowerBound ..< last.range.upperBound)
            }
        }
        return groups
    }

    // MARK: - Markers and Separators

    /// The columns of a marker to leave out. An opening marker loses its `//` or `/*` and the space
    /// after it, and keeps the alignment spaces a continuation line has beyond that — the lines of
    /// an enum case's block stay indented under its header. A closing ` */` goes whole.
    static func hiddenColumns(ofMarker marker: Range<Int>, in textUnits: [UInt16]) -> Range<Int> {
        let slash: UInt16 = 0x2F
        let asterisk: UInt16 = 0x2A
        guard marker.count >= 2,
              textUnits[marker.lowerBound] == slash,
              textUnits[marker.lowerBound + 1] == slash || textUnits[marker.lowerBound + 1] == asterisk
        else { return marker }
        var end = marker.lowerBound + 2
        if end < marker.upperBound, textUnits[end] == 0x20 {
            end += 1
        }
        return marker.lowerBound ..< end
    }

    /// The punctuation a separator loses: syntax rather than meaning.
    private static let hiddenPunctuation: Set<UInt16> = [
        0x3A, // :
        0x28, // (
        0x29, // )
        0x2C, // ,
        0x3B, // ;
        0x60, // `
        0x2014, // —
        0x23, // #
    ]

    /// The columns of a separator to leave out: its hidden punctuation, and — when what is left is
    /// only whitespace — all of that whitespace but one, so two runs stay one space apart.
    static func hiddenColumns(ofSeparator separator: Range<Int>, in textUnits: [UInt16]) -> [Range<Int>] {
        var hidden: [Range<Int>] = []
        var keptWhitespace: [Int] = []
        var keepsSomethingElse = false
        for offset in separator {
            let unit = textUnits[offset]
            if hiddenPunctuation.contains(unit) {
                hidden.append(offset ..< offset + 1)
            } else if unit == 0x20 || unit == 0x09 {
                keptWhitespace.append(offset)
            } else {
                keepsSomethingElse = true
            }
        }
        if !keepsSomethingElse, hidden.count > 0, keptWhitespace.count > 1 {
            for offset in keptWhitespace.dropLast() {
                hidden.append(offset ..< offset + 1)
            }
        }
        return merged(hidden)
    }

    private static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var result: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, last.upperBound >= range.lowerBound {
                result[result.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                result.append(range)
            }
        }
        return result
    }

    // MARK: - Collapsing

    private static func collapsibles(
        in structure: RuntimeInterfaceCommentStructure,
        commentRanges: [Range<Int>?],
        segmentsByComment: [[(role: RuntimeInterfaceCommentStructure.Role, range: Range<Int>)]],
        lines: Lines,
        textUnits: [UInt16]
    ) -> [Collapsible] {
        var childKindsByComment = [Set<RuntimeInterfaceCommentStructure.Kind>](repeating: [], count: structure.comments.count)
        var childIndicesByComment = [[Int]](repeating: [], count: structure.comments.count)
        for (index, comment) in structure.comments.enumerated() {
            guard let parent = comment.enclosingCommentIndex else { continue }
            childKindsByComment[parent].insert(comment.kind)
            childIndicesByComment[parent].append(index)
        }

        var collapsibles: [Collapsible] = []
        for (index, comment) in structure.comments.enumerated() {
            guard let range = commentRanges[index] else { continue }

            switch comment.kind {
            case .fieldOffset, .fieldLayoutNode:
                guard childKindsByComment[index].contains(.fieldLayoutNode) else { continue }
                let rowLine = lines.line(containing: range.lowerBound)
                let disclosure: Range<Int>
                if let treePrefix = segmentsByComment[index].first(where: { $0.role == .treePrefix })?.range {
                    // The `├── ` cell at the end of the prefix.
                    disclosure = max(treePrefix.lowerBound, treePrefix.upperBound - 4) ..< treePrefix.upperBound
                } else {
                    disclosure = indentationCell(before: range.lowerBound, onLine: rowLine, lines: lines, textUnits: textUnits)
                }
                if let collapsible = collapsible(rowLine: rowLine, endingAt: range.upperBound, disclosure: disclosure, lines: lines) {
                    collapsibles.append(collapsible)
                }

            case .enumLayoutCase:
                guard let headerIndex = childIndicesByComment[index].first(where: { structure.comments[$0].kind == .enumLayoutCaseHeader }),
                      let headerRange = commentRanges[headerIndex]
                else { continue }
                let headerLine = lines.line(containing: headerRange.lowerBound)
                let disclosure = indentationCell(before: headerRange.lowerBound, onLine: headerLine, lines: lines, textUnits: textUnits)
                if let collapsible = collapsible(rowLine: headerLine, endingAt: range.upperBound, disclosure: disclosure, lines: lines) {
                    collapsibles.append(collapsible)
                }

            default:
                continue
            }
        }
        return collapsibles
    }

    /// A row on `rowLine` whose lines run to `end`; nil when nothing follows the row's own line.
    private static func collapsible(rowLine: Int, endingAt end: Int, disclosure: Range<Int>, lines: Lines) -> Collapsible? {
        let foldStart = lines.end(ofLine: rowLine)
        guard end > foldStart, lines.line(containing: end - 1) > rowLine else { return nil }
        return Collapsible(disclosureRange: NSRange(disclosure), foldRange: NSRange(foldStart ..< end), startsCollapsed: true)
    }

    /// The two columns of indentation in front of `offset`, where a row without a tree prefix has
    /// its triangle; empty when there are not two spaces there.
    private static func indentationCell(before offset: Int, onLine line: Int, lines: Lines, textUnits: [UInt16]) -> Range<Int> {
        let cell = offset - 2 ..< offset
        guard cell.lowerBound >= lines.start(ofLine: line),
              cell.allSatisfy({ textUnits[$0] == 0x20 })
        else { return offset ..< offset }
        return cell
    }

    // MARK: - Text

    /// The UTF-16 offset of each UTF-8 offset that falls on a scalar boundary of `text`, in one
    /// pass over the text.
    static func utf16Offsets(of utf8Offsets: [Int], in text: String) -> [Int: Int] {
        let wanted = Array(Set(utf8Offsets)).sorted()
        var result: [Int: Int] = [:]
        result.reserveCapacity(wanted.count)
        var wantedIndex = 0
        var utf8Offset = 0
        var utf16Offset = 0
        for scalar in text.unicodeScalars {
            while wantedIndex < wanted.count, wanted[wantedIndex] <= utf8Offset {
                if wanted[wantedIndex] == utf8Offset {
                    result[utf8Offset] = utf16Offset
                }
                wantedIndex += 1
            }
            guard wantedIndex < wanted.count else { return result }
            utf8Offset += UTF8.width(scalar)
            utf16Offset += UTF16.width(scalar)
        }
        while wantedIndex < wanted.count, wanted[wantedIndex] <= utf8Offset {
            if wanted[wantedIndex] == utf8Offset {
                result[utf8Offset] = utf16Offset
            }
            wantedIndex += 1
        }
        return result
    }

    /// Where the generator printed an error — an address that does not resolve — as UTF-16 ranges.
    private static func errorRanges(in interfaceString: FrozenSemanticString) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var location = 0
        interfaceString.enumerateSpans { spanText, semanticType, _ in
            let length = spanText.utf16.count
            defer { location += length }
            if semanticType == .error, length > 0 {
                ranges.append(location ..< location + length)
            }
        }
        return ranges
    }

    /// Where each line starts, in UTF-16 offsets.
    struct Lines {
        private let lineStarts: [Int]
        private let textLength: Int

        init(textUnits: [UInt16]) {
            var lineStarts = [0]
            for (offset, unit) in textUnits.enumerated() where unit == 0x0A {
                lineStarts.append(offset + 1)
            }
            self.lineStarts = lineStarts
            self.textLength = textUnits.count
        }

        func line(containing offset: Int) -> Int {
            var low = 0
            var high = lineStarts.count - 1
            while low < high {
                let middle = (low + high + 1) / 2
                if lineStarts[middle] <= offset {
                    low = middle
                } else {
                    high = middle - 1
                }
            }
            return low
        }

        func start(ofLine line: Int) -> Int {
            lineStarts[line]
        }

        /// The offset of the line's line break, or of the end of the text on the last line.
        func end(ofLine line: Int) -> Int {
            line + 1 < lineStarts.count ? lineStarts[line + 1] - 1 : textLength
        }
    }
}
