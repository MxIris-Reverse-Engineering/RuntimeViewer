import Foundation
import RuntimeViewerCore
import Semantic
import Testing
@testable import RuntimeViewerApplication

/// Pins the policy that turns a comment structure into what the SourceEditor pane draws: what is
/// hidden, which run takes which colour, which runs a tag covers, and which rows collapse.
///
/// The structures are written the way MachOSwiftSection and MachOObjCSection divide their comments
/// (their proposals list every segment), and the fixture text has the box-drawing tree prefixes,
/// which are three UTF-8 bytes and one UTF-16 unit each — so every range here also passes through
/// the UTF-8 to UTF-16 conversion off the ASCII path.
@Suite("InterfaceCommentDecorations")
struct InterfaceCommentDecorationsTests {
    private static let swiftText = """
    struct Probe {
        // Address: 0x135DC
        // Type Layout: (size: 16, stride: 16, alignment: 8, extraInhabitantCount: 0)
        // Field offset: 0x8
        // ├── origin (__C.CGPoint): 0x8
        // │   └── x (CoreGraphics.CGFloat): 0x8
        // └── size (__C.CGSize): 0x18
        let rect: CGRect
        /* Enum Layout */
        // Case 1 (0x01) `thin` — empty case #0
        //   encoding: stored as an extra tag byte
        //       offset 0x08 = 0x01 (0b00000001)
        case thin
    }
    """

    private static func swiftFixture() -> (decorations: InterfaceCommentDecorations, text: Fixture) {
        let fixture = Fixture(text: swiftText)

        let address = fixture.comment(.memberAddress, lines: 1 ... 1)
        fixture.segments(in: address, onLine: 1, [(.marker, "// "), (.label, "Address"), (.separator, ": "), (.value, "0x135DC")])

        let typeLayout = fixture.comment(.typeLayout, lines: 2 ... 2)
        fixture.segments(in: typeLayout, onLine: 2, [
            (.marker, "// "), (.label, "Type Layout"), (.separator, ": ("),
            (.key, "size"), (.separator, ": "), (.value, "16"), (.separator, ", "),
            (.key, "stride"), (.separator, ": "), (.value, "16"), (.separator, ", "),
            (.key, "alignment"), (.separator, ": "), (.value, "8"), (.separator, ", "),
            (.key, "extraInhabitantCount"), (.separator, ": "), (.value, "0"), (.separator, ")"),
        ])

        let fieldOffset = fixture.comment(.fieldOffset, lines: 3 ... 6)
        fixture.segments(in: fieldOffset, onLine: 3, [(.marker, "// "), (.label, "Field offset"), (.separator, ": "), (.value, "0x8")])
        let origin = fixture.comment(.fieldLayoutNode, lines: 4 ... 5, enclosedBy: fieldOffset)
        fixture.segments(in: origin, onLine: 4, [
            (.marker, "// "), (.treePrefix, "├── "), (.name, "origin"), (.separator, " ("),
            (.type, "__C.CGPoint"), (.separator, "): "), (.value, "0x8"),
        ])
        let x = fixture.comment(.fieldLayoutNode, lines: 5 ... 5, enclosedBy: origin)
        fixture.segments(in: x, onLine: 5, [
            (.marker, "// "), (.treePrefix, "│   └── "), (.name, "x"), (.separator, " ("),
            (.type, "CoreGraphics.CGFloat"), (.separator, "): "), (.value, "0x8"),
        ])
        let size = fixture.comment(.fieldLayoutNode, lines: 6 ... 6, enclosedBy: fieldOffset)
        fixture.segments(in: size, onLine: 6, [
            (.marker, "// "), (.treePrefix, "└── "), (.name, "size"), (.separator, " ("),
            (.type, "__C.CGSize"), (.separator, "): "), (.value, "0x18"),
        ])

        let enumCase = fixture.comment(.enumLayoutCase, lines: 8 ... 11)
        fixture.segments(in: enumCase, onLine: 8, [(.marker, "/* "), (.label, "Enum Layout"), (.marker, " */")])
        let header = fixture.comment(.enumLayoutCaseHeader, lines: 9 ... 9, enclosedBy: enumCase)
        fixture.segments(in: header, onLine: 9, [
            (.marker, "// "), (.label, "Case"), (.separator, " "), (.value, "1"), (.separator, " ("),
            (.value, "0x01"), (.separator, ") `"), (.name, "thin"), (.separator, "` — "),
            (.key, "empty case"), (.separator, " #"), (.value, "0"),
        ])
        let encoding = fixture.comment(.enumLayoutCaseEncoding, lines: 10 ... 10, enclosedBy: enumCase)
        fixture.segments(in: encoding, onLine: 10, [(.marker, "//   "), (.label, "encoding"), (.separator, ": "), (.text, "stored as an extra tag byte")])
        let byte = fixture.comment(.enumLayoutCaseByte, lines: 11 ... 11, enclosedBy: enumCase)
        fixture.segments(in: byte, onLine: 11, [
            (.marker, "//       "), (.label, "offset"), (.separator, " "), (.key, "0x08"), (.separator, " = "),
            (.value, "0x01"), (.separator, " ("), (.value, "0b00000001"), (.separator, ")"),
        ])

        let interfaceString = SemanticString { Standard(swiftText) }.frozen()
        return (InterfaceCommentDecorations(structure: fixture.structure, interfaceString: interfaceString), fixture)
    }

    // MARK: - Hidden

    @Test func markersAndSyntaxPunctuationAreHiddenButAlignmentAndOperatorsStay() {
        let (decorations, text) = Self.swiftFixture()
        let hidden = Set(decorations.hiddenRanges)

        #expect(hidden.contains(text.range(of: "// ", onLine: 1)))
        #expect(hidden.contains(text.range(of: ":", onLine: 1)))
        // The space before the value stays, to keep the label and the value apart.
        #expect(!hidden.contains { NSIntersectionRange($0, text.range(of: " 0x135DC", onLine: 1).prefix(1)).length > 0 })

        // A continuation line loses `// ` and keeps its alignment spaces.
        #expect(hidden.contains(text.range(of: "// ", onLine: 10)))
        #expect(!hidden.contains { NSIntersectionRange($0, text.range(of: "//   ", onLine: 10)).length > 3 })
        #expect(hidden.contains(text.range(of: "// ", onLine: 11)))

        // `/* ` and ` */` both go.
        #expect(hidden.contains(text.range(of: "/* ", onLine: 8)))
        #expect(hidden.contains(text.range(of: " */", onLine: 8)))

        // `=` says something; the brackets and the colon around it do not.
        #expect(!hidden.contains { NSIntersectionRange($0, text.range(of: "=", onLine: 11)).length > 0 })
        #expect(hidden.contains(text.range(of: "(", onLine: 11)))

        // `` ` — `` keeps one of its two spaces.
        let dashSeparator = text.range(of: "` — ", onLine: 9)
        let hiddenInDash = decorations.hiddenRanges.reduce(0) { $0 + NSIntersectionRange($1, dashSeparator).length }
        #expect(hiddenInDash == 3)
    }

    // MARK: - Runs

    @Test func runsTakeTheColourOfTheirRole() {
        let (decorations, text) = Self.swiftFixture()
        let runs = Dictionary(decorations.runs.map { ($0.range, $0.style) }, uniquingKeysWith: { first, _ in first })

        #expect(runs[text.range(of: "Address", onLine: 1)] == .label)
        #expect(runs[text.range(of: "0x135DC", onLine: 1)] == .value)
        #expect(runs[text.range(of: "size", onLine: 2)] == .label)
        #expect(runs[text.range(of: "origin", onLine: 4)] == .name)
        #expect(runs[text.range(of: "__C.CGPoint", onLine: 4)] == .type)
        #expect(runs[text.range(of: "├── ", onLine: 4)] == .concealed)
        #expect(runs[text.range(of: "│   └── ", onLine: 5)] == .concealed)
        #expect(runs[text.range(of: "stored as an extra tag byte", onLine: 10)] == nil)
    }

    // MARK: - Tags

    @Test func eachFactGetsItsOwnTag() {
        let (decorations, text) = Self.swiftFixture()
        let tags = decorations.tags.map(\.range)

        #expect(tags.contains(text.range(of: "Address: 0x135DC", onLine: 1)))

        for fact in ["Type Layout", "size: 16", "stride: 16", "alignment: 8", "extraInhabitantCount: 0"] {
            #expect(tags.contains(text.range(of: fact, onLine: 2)), "no tag over \(fact)")
        }

        // A tree row tags its offset alone; its name and type are coloured, not tagged.
        #expect(tags.contains(text.range(of: "0x8", onLine: 4)))
        #expect(!tags.contains { NSIntersectionRange($0, text.range(of: "origin", onLine: 4)).length > 0 })

        // The case header: what it is, its name, which kind of case.
        #expect(tags.contains(text.range(of: "Case 1 (0x01", onLine: 9)))
        #expect(tags.contains(text.range(of: "thin", onLine: 9)))
        #expect(tags.contains(text.range(of: "empty case #0", onLine: 9)))

        // Prose stays outside: only the label of the encoding line is a tag.
        #expect(tags.contains(text.range(of: "encoding", onLine: 10)))
        #expect(!tags.contains { NSIntersectionRange($0, text.range(of: "stored", onLine: 10)).length > 0 })

        // A byte row: the offset and its value, the binary after it outside.
        #expect(tags.contains(text.range(of: "offset 0x08 = 0x01", onLine: 11)))
        #expect(!tags.contains { NSIntersectionRange($0, text.range(of: "0b00000001", onLine: 11)).length > 0 })

        // `/* Enum Layout */` is a note.
        #expect(decorations.tags.first { $0.range == text.range(of: "Enum Layout", onLine: 8) }?.style == .note)
    }

    @Test func anErrorInsideATagMakesItAWarning() {
        let semanticString = SemanticString {
            Standard("- (void)probe; ")
            Comment("IMP: ")
            Error("<invalid 0x0>")
        }
        let text = semanticString.string
        let fixture = Fixture(text: text)
        let imp = fixture.comment(.impAddress, lines: 0 ... 0, startingAt: "// ")
        fixture.segments(in: imp, onLine: 0, [(.marker, "// "), (.label, "IMP"), (.separator, ": "), (.value, "<invalid 0x0>")])

        let decorations = InterfaceCommentDecorations(structure: fixture.structure, interfaceString: semanticString.frozen())

        #expect(decorations.tags.map(\.style) == [.warning])
    }

    // MARK: - Collapsing

    @Test func layoutRowsWithRowsBelowThemAndCaseHeadersCollapse() {
        let (decorations, text) = Self.swiftFixture()
        let collapsibles = decorations.collapsibles

        #expect(collapsibles.count == 3, "\(collapsibles)")
        #expect(collapsibles.allSatisfy { $0.startsCollapsed })

        // The root: its triangle in the indentation, the whole tree under it.
        #expect(collapsibles.contains {
            $0.disclosureRange == text.columns(2 ..< 4, onLine: 3)
                && $0.foldRange == text.range(from: text.endOfLine(3), to: text.endOfLine(6))
        })
        // `origin`: its triangle in the `├── ` cell, only `x` under it. `x` and `size` are leaves.
        #expect(collapsibles.contains {
            $0.disclosureRange == text.range(of: "├── ", onLine: 4)
                && $0.foldRange == text.range(from: text.endOfLine(4), to: text.endOfLine(5))
        })
        // The case: collapses to its header, not to `/* Enum Layout */`.
        #expect(collapsibles.contains {
            $0.disclosureRange == text.columns(2 ..< 4, onLine: 9)
                && $0.foldRange == text.range(from: text.endOfLine(9), to: text.endOfLine(11))
        })
    }

    // MARK: - Untrusted Ranges

    @Test func rangesThatDoNotFitTheTextAreLeftOut() {
        let text = "// Address: 0x1"
        let structure = RuntimeInterfaceCommentStructure(
            comments: [
                .init(kind: .memberAddress, utf8Range: 0 ..< 15, enclosingCommentIndex: nil),
                .init(kind: .memberAddress, utf8Range: 10 ..< 400, enclosingCommentIndex: nil),
            ],
            segments: [
                .init(role: .marker, utf8Range: 0 ..< 3, commentIndex: 0),
                .init(role: .value, utf8Range: 300 ..< 310, commentIndex: 1),
                .init(role: .value, utf8Range: 12 ..< 15, commentIndex: 7),
            ]
        )

        let decorations = InterfaceCommentDecorations(structure: structure, interfaceString: SemanticString { Standard(text) }.frozen())

        #expect(decorations.hiddenRanges == [NSRange(location: 0, length: 3)])
        #expect(decorations.tags.isEmpty)
        #expect(decorations.runs.isEmpty)
    }

    // MARK: - Pipeline

    @Test func aRenderedInterfaceCarriesTheDecorationsOfItsCommentStructure() {
        let (_, fixture) = Self.swiftFixture()
        let runtimeObject = RuntimeObject(name: "Probe", displayName: "Probe", kind: .swift(.type(.struct)), imagePath: "/Probe", children: [])
        let fetched = ContentTextViewModel.FetchedInterface(
            interfaceString: SemanticString { Standard(Self.swiftText) }.frozen(),
            runtimeObject: runtimeObject,
            commentStructure: fixture.structure
        )

        let rendered = ContentTextViewModel.renderInterface(for: fetched, theme: ResolvedTheme.fallback)
        #expect(rendered?.commentDecorations?.collapsibles.count == 3)

        let unstructured = ContentTextViewModel.FetchedInterface(interfaceString: fetched.interfaceString, runtimeObject: runtimeObject, commentStructure: nil)
        #expect(ContentTextViewModel.renderInterface(for: unstructured, theme: ResolvedTheme.fallback)?.commentDecorations == nil)
    }

    /// The note the pane prints in place of an interface Print Exported Declarations Only empties
    /// is drawn like the comments around it.
    @Test func theExportedOnlyNoteIsDrawnAsNotes() {
        let runtimeObject = RuntimeObject(name: "Probe", displayName: "Probe", kind: .swift(.type(.struct)), imagePath: "/Probe", children: [])
        var options = RuntimeObjectInterface.GenerationOptions()
        options.swiftInterfaceOptions.printExportedDeclarationsOnly = true

        let displayed = ContentTextViewModel.displayedInterface(of: RuntimeObjectInterface(object: runtimeObject, interfaceString: ""), runtimeObject: runtimeObject, options: options)
        let structure = try? #require(displayed.commentStructure)
        let decorations = structure.map { InterfaceCommentDecorations(structure: $0, interfaceString: displayed.interfaceString) }

        #expect(decorations?.tags.count == 2)
        #expect(decorations?.tags.allSatisfy { $0.style == .note } == true)
        #expect(decorations?.hiddenRanges.count == 2)
    }
}

// MARK: - Fixture

/// Writes a comment structure against a text by naming the text of each segment on its line, in
/// order, and answers the UTF-16 ranges the decorations are expected at.
private final class Fixture {
    private let lines: [String]
    private let utf8LineStarts: [Int]
    private let utf16LineStarts: [Int]
    private var comments: [RuntimeInterfaceCommentStructure.Comment] = []
    private var segments: [RuntimeInterfaceCommentStructure.Segment] = []

    init(text: String) {
        lines = text.components(separatedBy: "\n")
        var utf8Start = 0
        var utf16Start = 0
        var utf8LineStarts: [Int] = []
        var utf16LineStarts: [Int] = []
        for line in lines {
            utf8LineStarts.append(utf8Start)
            utf16LineStarts.append(utf16Start)
            utf8Start += line.utf8.count + 1
            utf16Start += line.utf16.count + 1
        }
        self.utf8LineStarts = utf8LineStarts
        self.utf16LineStarts = utf16LineStarts
    }

    var structure: RuntimeInterfaceCommentStructure {
        RuntimeInterfaceCommentStructure(comments: comments, segments: segments)
    }

    /// A comment from the first `//` or `/*` of its first line to the end of its last line.
    @discardableResult
    func comment(
        _ kind: RuntimeInterfaceCommentStructure.Kind,
        lines lineRange: ClosedRange<Int>,
        enclosedBy enclosingIndex: Int? = nil,
        startingAt marker: String? = nil
    ) -> Int {
        let firstLine = lines[lineRange.lowerBound]
        let markerStart = marker.flatMap { firstLine.range(of: $0) }
            ?? firstLine.range(of: "//")
            ?? firstLine.range(of: "/*")!
        let start = utf8LineStarts[lineRange.lowerBound] + firstLine.utf8.distance(from: firstLine.startIndex, to: markerStart.lowerBound)
        let end = utf8LineStarts[lineRange.upperBound] + lines[lineRange.upperBound].utf8.count
        comments.append(.init(kind: kind, utf8Range: start ..< end, enclosingCommentIndex: enclosingIndex))
        return comments.count - 1
    }

    /// Segments of `commentIndex` on `line`, each found after the one before it.
    func segments(in commentIndex: Int, onLine line: Int, _ parts: [(RuntimeInterfaceCommentStructure.Role, String)]) {
        let text = lines[line]
        var searchStart = text.startIndex
        for (role, part) in parts {
            let found = text.range(of: part, range: searchStart ..< text.endIndex)!
            let lower = utf8LineStarts[line] + text.utf8.distance(from: text.startIndex, to: found.lowerBound)
            segments.append(.init(role: role, utf8Range: lower ..< lower + part.utf8.count, commentIndex: commentIndex))
            searchStart = found.upperBound
        }
    }

    // MARK: Expected UTF-16 Ranges

    func range(of part: String, onLine line: Int) -> NSRange {
        let found = (lines[line] as NSString).range(of: part)
        precondition(found.location != NSNotFound, "\(part.debugDescription) is not on line \(line)")
        return NSRange(location: utf16LineStarts[line] + found.location, length: found.length)
    }

    func columns(_ columns: Range<Int>, onLine line: Int) -> NSRange {
        NSRange(location: utf16LineStarts[line] + columns.lowerBound, length: columns.count)
    }

    func endOfLine(_ line: Int) -> Int {
        utf16LineStarts[line] + lines[line].utf16.count
    }

    func range(from start: Int, to end: Int) -> NSRange {
        NSRange(location: start, length: end - start)
    }
}

private extension NSRange {
    /// The first `length` units of the range.
    func prefix(_ length: Int) -> NSRange {
        NSRange(location: location, length: Swift.min(length, self.length))
    }
}
