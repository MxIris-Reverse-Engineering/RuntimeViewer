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

/// A relationship query: the name to look up, which relationship to walk,
/// and how many matching types to build trees for.
public struct RuntimeTypeRelationshipsQuery: Hashable, Codable, Sendable {
    public var text: String
    public var relationship: RuntimeTypeRelationship
    public var isCaseSensitive: Bool
    /// Types whose name matches `text` exactly come first, then those that
    /// contain it; at most this many get a tree.
    public var candidateLimit: Int

    public init(text: String, relationship: RuntimeTypeRelationship, isCaseSensitive: Bool = false, candidateLimit: Int = 50) {
        self.text = text
        self.relationship = relationship
        self.isCaseSensitive = isCaseSensitive
        self.candidateLimit = candidateLimit
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
