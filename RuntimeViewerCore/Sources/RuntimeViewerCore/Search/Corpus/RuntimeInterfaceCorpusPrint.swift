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
