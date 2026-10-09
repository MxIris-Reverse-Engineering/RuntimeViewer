import Foundation
public import Semantic

public struct RuntimeObjectInterface: Codable, Sendable {
    public let object: RuntimeObject

    /// The generated interface in its immutable terminal form. A stored
    /// interface is only rendered, encoded, exported, or searched from here
    /// on — never recomposed — so it is frozen at this boundary: one text
    /// string plus 8-byte spans instead of the printer's component
    /// representation (~40 B/token flat, ~144 B/token as a construction
    /// tree). This type's own `Codable` is the columnar
    /// `FrozenSemanticString` encoding, an order of magnitude smaller over
    /// XPC/TCP; the interface request sends it only to a requester that says
    /// it reads it, and the component array builds up to 3.0.0-beta.6 read
    /// to everyone else — see `RuntimeObjectInterfaceResponse`.
    public let interfaceString: FrozenSemanticString

    public init(object: RuntimeObject, interfaceString: SemanticString) {
        self.object = object
        self.interfaceString = interfaceString.frozen()
    }

    public init(object: RuntimeObject, interfaceString: FrozenSemanticString) {
        self.object = object
        self.interfaceString = interfaceString
    }
}
