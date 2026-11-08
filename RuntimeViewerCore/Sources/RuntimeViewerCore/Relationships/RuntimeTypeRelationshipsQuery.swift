import Foundation

/// A relationship query: the name to look up and how to match it, which
/// relationship to walk, how many matching types to build trees for, and
/// which images the related types may come from.
public struct RuntimeTypeRelationshipsQuery: Hashable, Codable, Sendable {
    public var text: String
    /// How `text` is matched against a type's name: the text search's match
    /// styles under its rules, applied to the type's own name — the last
    /// component of its qualified name, where Xcode's type hierarchy queries
    /// anchor them — or to the whole qualified name when `text` has a dot in
    /// it. See `RuntimeInterfaceTextMatcher.typeNameMatches(_:pattern:budget:)`.
    public var matchMode: RuntimeInterfaceSearchMatchMode
    public var relationship: RuntimeTypeRelationship
    public var isCaseSensitive: Bool
    /// Types whose name is `text` itself come first, then the other matches;
    /// at most this many get a tree.
    public var candidateLimit: Int
    /// The images whose types the trees list; `nil` lists every indexed
    /// image's. The type named by `text` is looked up in every indexed image
    /// either way — the subclasses in Foundation of libobjc's `NSObject` are
    /// a fair question. A node from another image stays only when it leads
    /// to one of these images' types, and a tree left with no nodes is
    /// dropped.
    public var imagePaths: Set<String>?
    /// Types this engine has not indexed whose descendants or conformers it
    /// is asked for too, each answered as a tree of its own after the
    /// candidates' — whatever its name and the candidate limit. An engine
    /// that borrows shared cache images hands its owners' types here, so the
    /// serving process finds its own images' subclasses and conformers of
    /// them; the owners walk the shared cache's. Ignored for ancestors.
    /// Optional on the wire: a peer that predates it decodes the query
    /// without it and answers only for the candidates.
    public var externalRoots: [RuntimeObject]?

    public init(text: String, matchMode: RuntimeInterfaceSearchMatchMode = .containing, relationship: RuntimeTypeRelationship, isCaseSensitive: Bool = false, candidateLimit: Int = 50, imagePaths: Set<String>? = nil, externalRoots: [RuntimeObject]? = nil) {
        self.text = text
        self.matchMode = matchMode
        self.relationship = relationship
        self.isCaseSensitive = isCaseSensitive
        self.candidateLimit = candidateLimit
        self.imagePaths = imagePaths
        self.externalRoots = externalRoots
    }
}
