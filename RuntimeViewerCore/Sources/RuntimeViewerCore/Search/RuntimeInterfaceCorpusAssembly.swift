import Foundation
import Semantic

/// One object's interface as the corpus printed it, before its members are
/// located.
struct RuntimeInterfaceCorpusPrint: Sendable {
    let object: RuntimeObject

    /// Everything any Generation Options could show — see
    /// `RuntimeInterfaceCorpusEntry.interface`.
    let interface: FrozenSemanticString

    let visibilityRegions: VisibilityRegionTable

    /// The object's members as its structures list them, not located yet.
    let members: [RuntimeMemberDeclaration]

    /// The blocks `interface` prints the object's nested types in, ascending:
    /// each is an entry of its own, so its lines belong to it, not to this
    /// object. See `RuntimeInterfaceCorpusNesting`.
    let nestedDefinitionRanges: [Range<Int>]
}

/// What printing one object came to: its print, nothing to print, or the
/// error that made the corpus skip it.
enum RuntimeInterfaceCorpusPrintOutcome: Sendable {
    case printed(RuntimeInterfaceCorpusPrint)
    case empty
    case failed(String)
}

/// Makes an image's corpus entries out of its printed objects: each object's
/// members are located in its interface outside the blocks its nested types
/// take up, so the fields of a `Codable` type do not land on the `case` lines
/// of its synthesized `CodingKeys`. Off the store's actor, and pure.
enum RuntimeInterfaceCorpusAssembly {
    static func entries(from prints: [RuntimeInterfaceCorpusPrint]) -> [RuntimeInterfaceCorpusEntry] {
        prints.map { objectPrint in
            RuntimeInterfaceCorpusEntry(
                object: objectPrint.object,
                interface: objectPrint.interface,
                visibilityRegions: objectPrint.visibilityRegions,
                members: RuntimeMemberDeclarationLocator.locate(objectPrint.members, in: objectPrint.interface, excludingUTF8Ranges: objectPrint.nestedDefinitionRanges),
                nestedDefinitionRanges: objectPrint.nestedDefinitionRanges
            )
        }
    }
}
