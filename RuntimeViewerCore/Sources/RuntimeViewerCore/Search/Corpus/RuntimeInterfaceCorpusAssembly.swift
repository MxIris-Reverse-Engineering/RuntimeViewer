import Foundation
import Semantic

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
