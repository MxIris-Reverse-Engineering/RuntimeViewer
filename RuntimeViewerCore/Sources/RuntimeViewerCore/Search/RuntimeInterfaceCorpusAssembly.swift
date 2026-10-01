import Foundation
import Semantic

/// One object's interface as the corpus printed it, before the steps that
/// need the rest of the image: finding the blocks its nested types take up
/// and locating its members.
struct RuntimeInterfaceCorpusPrint: Sendable {
    let object: RuntimeObject

    /// Everything any Generation Options could show — see
    /// `RuntimeInterfaceCorpusEntry.interface`.
    let interface: FrozenSemanticString

    let visibilityRegions: VisibilityRegionTable

    /// The object's members as its structures list them, not located yet.
    let members: [RuntimeMemberDeclaration]

    /// UTF-8 length of the first definition `interface` prints — the
    /// object's own, ahead of its extensions. A parent prints exactly this
    /// text for its nested type, one level deeper.
    let ownDefinitionUTF8Length: Int
}

/// Makes an image's corpus entries out of its printed objects. Pure — no
/// actor, no engine — so its rules can be tested on hand-built prints.
///
/// It exists for nested types. A type's interface prints its nested types
/// inline, and the corpus holds every nested type as an entry of its own as
/// well, so without it a text search reports a nested type's lines twice —
/// once more in the parent — and the parent's members claim lines in the
/// nested types printed above its own: the fields of a `Codable` type land
/// on the `case` lines of its synthesized `CodingKeys`. So each parent
/// records the blocks its nested types occupy, found by looking for each
/// nested type's own definition, as its own entry printed it, one level
/// deeper in the parent's text; its members are located outside those
/// blocks, and a search skips them.
///
/// A block that cannot be found is simply not recorded, which costs a
/// duplicate search result, never a lost one.
enum RuntimeInterfaceCorpusAssembly {
    /// One indentation level, as the Swift printer writes it.
    static let indentation = Array("    ".utf8)

    static func entries(from prints: [RuntimeInterfaceCorpusPrint]) -> [RuntimeInterfaceCorpusEntry] {
        var printIndexByKey: [RuntimeObjectKey: Int] = [:]
        printIndexByKey.reserveCapacity(prints.count)
        for (index, objectPrint) in prints.enumerated() {
            printIndexByKey[objectPrint.object.key] = index
        }
        return prints.map { objectPrint in
            let children = objectPrint.object.children.compactMap { child in
                printIndexByKey[child.key].map { prints[$0] }
            }
            let nestedDefinitionRanges = nestedDefinitionRanges(in: objectPrint, children: children)
            return RuntimeInterfaceCorpusEntry(
                object: objectPrint.object,
                interface: objectPrint.interface,
                visibilityRegions: objectPrint.visibilityRegions,
                members: RuntimeMemberDeclarationLocator.locate(objectPrint.members, in: objectPrint.interface, excludingUTF8Ranges: nestedDefinitionRanges),
                nestedDefinitionRanges: nestedDefinitionRanges
            )
        }
    }

    /// The blocks `parent` prints for `children`, ascending. A child's block
    /// is its own definition one level deeper, starting at the start of a
    /// line and ending at the end of one; the first such occurrence not
    /// already claimed by an earlier child is taken.
    static func nestedDefinitionRanges(in parent: RuntimeInterfaceCorpusPrint, children: [RuntimeInterfaceCorpusPrint]) -> [Range<Int>] {
        guard !children.isEmpty else { return [] }
        var parentText = parent.interface.text
        var ranges: [Range<Int>] = []
        parentText.withUTF8 { parentBytes in
            for child in children {
                let block = indentedOwnDefinition(of: child)
                guard !block.isEmpty else { continue }
                var searchStart = 0
                while let start = firstOccurrence(of: block, in: parentBytes, from: searchStart) {
                    let range = start ..< start + block.count
                    let startsLine = start == 0 || parentBytes[start - 1] == UInt8(ascii: "\n")
                    let endsLine = range.upperBound == parentBytes.count || parentBytes[range.upperBound] == UInt8(ascii: "\n")
                    if startsLine, endsLine, !ranges.contains(where: { $0.overlaps(range) }) {
                        ranges.append(range)
                        break
                    }
                    searchStart = start + 1
                }
            }
        }
        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// The child's own definition with every line that has text in it moved
    /// one level in — every line of a multi-line comment included, since the
    /// parent indents those line by line too. Empty lines stay empty.
    static func indentedOwnDefinition(of objectPrint: RuntimeInterfaceCorpusPrint) -> [UInt8] {
        let ownDefinition = objectPrint.interface.text.utf8.prefix(objectPrint.ownDefinitionUTF8Length)
        var result: [UInt8] = []
        result.reserveCapacity(ownDefinition.count + ownDefinition.count / 8)
        var isAtLineStart = true
        for byte in ownDefinition {
            if isAtLineStart, byte != UInt8(ascii: "\n") {
                result.append(contentsOf: indentation)
            }
            result.append(byte)
            isAtLineStart = byte == UInt8(ascii: "\n")
        }
        return result
    }

    private static func firstOccurrence(of needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard let haystackBase = haystack.baseAddress, start + needle.count <= haystack.count else { return nil }
        return needle.withUnsafeBytes { needleBytes -> Int? in
            guard let found = memmem(haystackBase + start, haystack.count - start, needleBytes.baseAddress, needleBytes.count) else { return nil }
            return UnsafeRawPointer(haystackBase).distance(to: UnsafeRawPointer(found))
        }
    }
}
