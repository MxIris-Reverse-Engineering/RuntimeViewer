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

    /// What each comment of `interfaceString` is and how it divides, when the request asked for it;
    /// nil otherwise, and always nil from a peer that predates it, which leaves the key out of its
    /// reply. The text itself is the same either way.
    public let commentStructure: RuntimeInterfaceCommentStructure?

    /// The language `interfaceString` is written in: Objective-C for an Objective-C object's header,
    /// Swift for a Swift object and for an Objective-C one asked for as Swift imports it
    /// (`GenerationOptions.interfaceLanguage`). Always nil from a peer that predates it, which
    /// answers every request in the object's own language and leaves the key out of its reply.
    public let interfaceLanguage: RuntimeInterfaceLanguage?

    /// The attached macros `interfaceString` shows folded, with the declarations each generated, in
    /// text order, when the request asked for them (`GenerationOptions.marksAttachedMacros`); nil
    /// otherwise, and always nil from a peer that predates it, which leaves the key out of its reply.
    public let macroExpansions: [RuntimeInterfaceMacroExpansion]?

    public init(object: RuntimeObject, interfaceString: SemanticString, commentStructure: RuntimeInterfaceCommentStructure? = nil, interfaceLanguage: RuntimeInterfaceLanguage? = nil, macroExpansions: [RuntimeInterfaceMacroExpansion]? = nil) {
        self.object = object
        self.interfaceString = interfaceString.frozen()
        self.commentStructure = commentStructure
        self.interfaceLanguage = interfaceLanguage
        self.macroExpansions = macroExpansions
    }

    public init(object: RuntimeObject, interfaceString: FrozenSemanticString, commentStructure: RuntimeInterfaceCommentStructure? = nil, interfaceLanguage: RuntimeInterfaceLanguage? = nil, macroExpansions: [RuntimeInterfaceMacroExpansion]? = nil) {
        self.object = object
        self.interfaceString = interfaceString
        self.commentStructure = commentStructure
        self.interfaceLanguage = interfaceLanguage
        self.macroExpansions = macroExpansions
    }
}
