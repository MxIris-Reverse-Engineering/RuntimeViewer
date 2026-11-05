import Foundation

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
