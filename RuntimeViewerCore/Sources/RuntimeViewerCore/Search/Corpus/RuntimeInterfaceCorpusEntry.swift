import Foundation
import FoundationToolbox
import Semantic

/// One object's contribution to the corpus: its interface, printed once with
/// everything any Generation Options could show, the regions saying which
/// options hide which parts of it, and the members its structures list, each
/// aligned with a line of that interface.
struct RuntimeInterfaceCorpusEntry: Sendable {
    let object: RuntimeObject

    /// Everything any Generation Options could show; a search reads it
    /// through `visibilityRegions` under the options it was given.
    let interface: FrozenSemanticString

    /// Its conditions are the copies the image's corpus stores once for all
    /// its entries — see `RuntimeInterfaceVisibilityConditionPool`.
    private(set) var visibilityRegions: VisibilityRegionTable

    /// The members its structures list, located, but without their
    /// declaration lines: each `declarationText` is the member's name,
    /// sharing its storage, and `displayedMember(at:)` reads the line back
    /// out of `interface` for a member that is shown. A copy of every line
    /// costs about as much as the text itself for a type of mostly members.
    let members: [RuntimeMemberDeclaration]

    /// Where each member's declaration line lies in `interface`, as UTF-8
    /// offsets — `nil` for a member the locator found no line for. A member
    /// is shown under some options when something of its line survives the
    /// projection.
    let memberDeclarationLineRanges: [Range<Int>?]

    /// The blocks `interface` prints for the object's nested types, as UTF-8
    /// offsets in ascending order. Each nested type is an entry of its own,
    /// so a text search skips these and reports their lines there — see
    /// `RuntimeInterfaceCorpusAssembly`.
    let nestedDefinitionRanges: [Range<Int>]

    init(
        object: RuntimeObject,
        interface: FrozenSemanticString,
        visibilityRegions: VisibilityRegionTable = .empty,
        members: [RuntimeMemberDeclaration],
        nestedDefinitionRanges: [Range<Int>] = []
    ) {
        self.object = object
        self.interface = interface
        self.visibilityRegions = visibilityRegions
        self.members = members.map { member in
            RuntimeMemberDeclaration(name: member.name, kind: member.kind, isStatic: member.isStatic, declarationText: member.name, lineNumber: member.lineNumber)
        }
        self.nestedDefinitionRanges = nestedDefinitionRanges
        let lineTable = RuntimeInterfaceLineTable(interface.text)
        memberDeclarationLineRanges = members.map { member in
            guard let lineNumber = member.lineNumber, lineNumber >= 1, lineNumber <= lineTable.lineCount else { return nil }
            return lineTable.lineUTF8Range(at: lineNumber - 1)
        }
    }

    /// Resident bytes, estimated from what the entry allocates — its
    /// interface's text, span table and identifiers, its region table, its
    /// members with their names and line ranges, its nested blocks, and what
    /// its object holds — each allocation with its header and malloc's
    /// rounding (`allocatedByteCount`). Counted by element alone, as it used
    /// to be, the estimate fell a tenth short of what evicting Foundation's
    /// corpus frees — a fifth before the corpus stored its visibility
    /// conditions once.
    ///
    /// Not the entry itself, which the corpus's array of entries holds, nor
    /// its visibility conditions, which the corpus stores once for all its
    /// entries; `ImageCorpus.init(sharingVisibilityConditionsOf:…)` counts
    /// both. A member's `declarationText` shares its name's buffer.
    var byteCount: Int {
        interface.text.allocatedByteCount
            + interface.spans.allocatedByteCount
            + interface.identifierTable.reduce(interface.identifierTable.allocatedByteCount) { total, identifier in total + identifier.allocatedByteCount }
            + visibilityRegions.regions.allocatedByteCount
            + members.reduce(members.allocatedByteCount) { total, member in total + member.name.allocatedByteCount }
            + memberDeclarationLineRanges.allocatedByteCount
            + nestedDefinitionRanges.allocatedByteCount
            + object.name.allocatedByteCount
            + object.displayName.allocatedByteCount
            + object.children.allocatedByteCount
            + object.privateDeclarations.allocatedByteCount
    }

    /// Takes `visibilityRegions` back with its conditions swapped for the
    /// copies `pool` stores, which the image's other entries share.
    mutating func shareVisibilityConditions(in pool: inout RuntimeInterfaceVisibilityConditionPool) {
        visibilityRegions = pool.sharedTable(for: visibilityRegions)
    }

    /// The interface as it reads under `visibility`: `interface` itself when
    /// nothing in it depends on the options.
    func projection(under visibility: RuntimeInterfaceVisibility) -> VisibilityProjection? {
        guard !visibilityRegions.isEmpty else { return nil }
        RuntimeInterfaceSearchWorkLog.record(.projection)
        return visibilityRegions.projection(of: interface, where: visibility.isOptionEnabled)
    }

    /// Whether `pattern` can hit the interface as `visibility` shows it,
    /// decided without building that projection, which copies the entry
    /// several times over. Never no for an entry the projection gives a hit
    /// in, so a search can skip the entry on a no; see
    /// `RuntimeInterfaceTextMatcher.literalPattern(_:mayHitTextOf:hidingUTF8Ranges:)`.
    /// Always yes for a regular expression.
    func mayHaveHits(of pattern: RuntimeInterfaceTextMatcher.Pattern, under visibility: RuntimeInterfaceVisibility) -> Bool {
        guard pattern.regex == nil else { return true }
        let hiddenRanges = visibilityRegions.hiddenUTF8Ranges(inTextOfUTF8Count: interface.text.utf8.count, where: visibility.isOptionEnabled)
        return RuntimeInterfaceTextMatcher.literalPattern(pattern, mayHitTextOf: interface.text, hidingUTF8Ranges: hiddenRanges)
    }

    /// The member at `memberIndex` as the full interface shows it, its
    /// declaration line read back out of `interface` and trimmed of its
    /// indentation, as the locator wrote it. A member with no known line
    /// keeps its name as its declaration.
    func displayedMember(at memberIndex: Int) -> RuntimeMemberDeclaration {
        let member = members[memberIndex]
        guard let lineNumber = member.lineNumber, let lineRange = memberDeclarationLineRanges[memberIndex] else { return member }
        let lineText = String(decoding: interface.text.utf8.dropFirst(lineRange.lowerBound).prefix(lineRange.count), as: UTF8.self)
        return member.located(at: lineNumber, declarationText: lineText.trimmingCharacters(in: .whitespaces))
    }

    /// `nestedDefinitionRanges` in `projection`'s text: each block from its
    /// first to its last byte the projection kept. The projection keeps the
    /// order of what it keeps, so nothing outside a block lands inside it; a
    /// block it removed whole maps to nothing.
    func nestedDefinitionRanges(in projection: VisibilityProjection) -> [Range<Int>] {
        nestedDefinitionRanges.compactMap { range in
            guard let firstKept = range.lazy.compactMap({ projection.projectedUTF8Offset(ofOriginalUTF8Offset: $0) }).first,
                  let lastKept = range.reversed().lazy.compactMap({ projection.projectedUTF8Offset(ofOriginalUTF8Offset: $0) }).first
            else { return nil }
            return firstKept ..< lastKept + 1
        }
    }

    /// The member at `memberIndex` as the projection shows it — its line
    /// number and declaration line in the projected text — or `nil` when the
    /// projection hid it. A member with no known line is kept as it is.
    func member(at memberIndex: Int, in projection: VisibilityProjection, projectedLineTable: RuntimeInterfaceLineTable) -> RuntimeMemberDeclaration? {
        let member = members[memberIndex]
        guard let lineRange = memberDeclarationLineRanges[memberIndex] else { return member }
        let originalBytes = interface.text.utf8
        var surviving: Int?
        var byteIndex = originalBytes.index(originalBytes.startIndex, offsetBy: lineRange.lowerBound)
        for byteOffset in lineRange {
            let byte = originalBytes[byteIndex]
            if byte != UInt8(ascii: " "), byte != UInt8(ascii: "\t"), let projectedOffset = projection.projectedUTF8Offset(ofOriginalUTF8Offset: byteOffset) {
                surviving = projectedOffset
                break
            }
            byteIndex = originalBytes.index(after: byteIndex)
        }
        guard let surviving else { return nil }
        let lineIndex = projectedLineTable.lineIndex(containingUTF8Offset: surviving)
        let projectedLineRange = projectedLineTable.lineUTF8Range(at: lineIndex)
        let lineText = String(decoding: projection.text.text.utf8.dropFirst(projectedLineRange.lowerBound).prefix(projectedLineRange.count), as: UTF8.self)
        return member.located(at: lineIndex + 1, declarationText: lineText.trimmingCharacters(in: .whitespaces))
    }
}
