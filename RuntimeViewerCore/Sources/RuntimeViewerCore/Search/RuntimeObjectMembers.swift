import Foundation

/// One object of an image's Find corpus with the members its interface lists,
/// as `RuntimeEngine.members(in:shownUnder:)` answers: names, not declarations.
///
/// Light on purpose. An image's members run to tens of thousands, and what
/// asks for all of them — the naming word cloud counts the words in their
/// names — needs no declaration line; the object carries no `children`
/// either, since every nested type is an entry of the corpus in its own right.
public struct RuntimeObjectMembers: Hashable, Codable, Sendable {
    /// The object, without its `children`.
    public let object: RuntimeObject

    /// The members the options show, in the order the interface lists them.
    public let members: [Member]

    public init(object: RuntimeObject, members: [Member]) {
        self.object = RuntimeObject(
            name: object.name,
            displayName: object.displayName,
            kind: object.kind,
            imagePath: object.imagePath,
            children: [],
            properties: object.properties,
            privateDeclarations: object.privateDeclarations
        )
        self.members = members
    }

    /// A member as `RuntimeMemberDeclaration` has it, without its
    /// declaration line.
    public struct Member: Hashable, Codable, Sendable {
        /// The member's own name; see `RuntimeMemberDeclaration.name`.
        public let name: String

        public let kind: RuntimeMemberKind

        /// Class members on the ObjC side, static or class members on the Swift side.
        public let isStatic: Bool

        /// The 1-based line of the declaration in the interface as the
        /// options show it, or `nil` when the printed text could not be
        /// aligned with the structure.
        public let lineNumber: Int?

        public init(name: String, kind: RuntimeMemberKind, isStatic: Bool, lineNumber: Int?) {
            self.name = name
            self.kind = kind
            self.isStatic = isStatic
            self.lineNumber = lineNumber
        }
    }
}
