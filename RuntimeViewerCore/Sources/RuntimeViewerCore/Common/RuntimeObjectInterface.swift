import Foundation
public import Semantic

public struct RuntimeObjectInterface: Codable, Sendable {
    public let object: RuntimeObject

    public let interfaceString: SemanticString

    public init(object: RuntimeObject, interfaceString: SemanticString) {
        self.object = object
        // A stored interface is finalized: it is only rendered, encoded, or
        // searched from here on — never recomposed through element
        // boundaries. Compacting drops the printer's composite element tree
        // and its per-token existential boxes, keeping only the flat typed
        // component array (~40 B/token instead of ~144 B/token). This is
        // what keeps `RuntimeSwiftSection.interfaceByObject` from retaining
        // the whole construction tree per cached interface. Decoded
        // interfaces skip this initializer, but their `SemanticString`
        // decodes straight into the flat form anyway.
        self.interfaceString = interfaceString.compacted()
    }
}
