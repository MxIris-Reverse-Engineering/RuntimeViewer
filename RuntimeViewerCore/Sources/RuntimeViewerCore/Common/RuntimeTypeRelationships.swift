import Foundation

/// The three relationship views of the Find navigator, with Xcode's
/// semantics:
///
/// - `ancestors` — a class's whole superclass chain, the protocols each level
///   adopts, and the protocols those refine; a protocol's refined protocols;
///   a struct's or enum's adopted protocols.
/// - `descendants` — every transitive subclass of a class, nested by level;
///   every protocol refining a protocol, recursively.
/// - `conformers` — the types adopting a protocol directly, the same set the
///   Inspector's Relationships tab shows.
public enum RuntimeTypeRelationship: String, Codable, Hashable, Sendable, CaseIterable {
    case ancestors
    case descendants
    case conformers
}

/// A relationship query: the name to look up and how to match it, which
/// relationship to walk, how many matching types to build trees for, and
/// which images the related types may come from.
public struct RuntimeTypeRelationshipsQuery: Hashable, Codable, Sendable {
    public var text: String
    /// How `text` is matched against a type's name: the text search's match
    /// styles under its rules, applied to the type's own name — the last
    /// component of its qualified name, where Xcode's type hierarchy queries
    /// anchor them — or to the whole qualified name when `text` has a dot in
    /// it. See `RuntimeInterfaceTextMatcher.typeNameMatches(_:pattern:)`.
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

/// One node of a relationship tree.
///
/// `object` is `nil` for a type no indexed image defines — a superclass in a
/// framework that was never indexed, a protocol only known by name from a
/// requirement signature. The node still shows up under `name`; it just
/// cannot be navigated to.
public struct RuntimeRelationshipNode: Hashable, Codable, Sendable {
    public let name: String
    public let object: RuntimeObject?
    public let children: [RuntimeRelationshipNode]

    public init(name: String, object: RuntimeObject?, children: [RuntimeRelationshipNode]) {
        self.name = name
        self.object = object
        self.children = children
    }

    public init(object: RuntimeObject, children: [RuntimeRelationshipNode] = []) {
        self.init(name: object.displayName, object: object, children: children)
    }

    public var isResolved: Bool { object != nil }
}

/// The tree for one type that matched the query: the type itself, then its
/// relationship nodes as the first level.
public struct RuntimeRelationshipTree: Hashable, Codable, Sendable {
    public let root: RuntimeObject
    public let nodes: [RuntimeRelationshipNode]

    public init(root: RuntimeObject, nodes: [RuntimeRelationshipNode]) {
        self.root = root
        self.nodes = nodes
    }
}
