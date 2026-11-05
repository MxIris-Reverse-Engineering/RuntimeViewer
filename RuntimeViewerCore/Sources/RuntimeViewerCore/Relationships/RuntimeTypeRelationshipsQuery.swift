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

    public init(text: String, matchMode: RuntimeInterfaceSearchMatchMode = .containing, relationship: RuntimeTypeRelationship, isCaseSensitive: Bool = false, candidateLimit: Int = 50, imagePaths: Set<String>? = nil) {
        self.text = text
        self.matchMode = matchMode
        self.relationship = relationship
        self.isCaseSensitive = isCaseSensitive
        self.candidateLimit = candidateLimit
        self.imagePaths = imagePaths
    }
}
