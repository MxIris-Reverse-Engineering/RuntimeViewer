import Foundation
import OrderedCollections

// How relationship trees built by different engines become one: an engine
// that borrows shared cache images walks its own images, its owners walk the
// shared cache's, and a tree crosses from one to the other wherever a type of
// one derives from a type of the other.

extension Array where Element == RuntimeRelationshipNode {
    /// These nodes, each node whose type `subtrees` names carrying that
    /// subtree's nodes underneath as well: another engine's descendants or
    /// conformers of a type this tree holds. A grafted node already present
    /// is not added twice.
    func grafting(_ subtrees: [RuntimeObject: [RuntimeRelationshipNode]]) -> [RuntimeRelationshipNode] {
        map { node in
            var children = node.children.grafting(subtrees)
            if let object = node.object, let graftedNodes = subtrees[object] {
                let presentObjects = Set(children.compactMap(\.object))
                children += graftedNodes.filter { graftedNode in
                    graftedNode.object.map { !presentObjects.contains($0) } ?? true
                }
            }
            return node.replacingChildren(children)
        }
    }

    /// The nodes for types of the images `isIncluded` accepts, and those
    /// leading to one — the cut `RuntimeTypeRelationshipsResolver` makes for a
    /// query's images, with the images given by a predicate.
    func leading(intoImagesWhere isIncluded: (String) -> Bool) -> [RuntimeRelationshipNode] {
        compactMap { node in
            let children = node.children.leading(intoImagesWhere: isIncluded)
            let isInImages = node.object.map { isIncluded($0.imagePath) } ?? false
            guard isInImages || !children.isEmpty else { return nil }
            return node.replacingChildren(children)
        }
    }

    /// Every type the nodes hold, depth first.
    var allObjects: [RuntimeObject] {
        flatMap { node in
            (node.object.map { [$0] } ?? []) + node.children.allObjects
        }
    }

    /// The types of the nodes no image of the engine that built them
    /// defines, in the order they appear. `assumedKind` stands in for the
    /// kind of a node that does not say — one a peer of an earlier release
    /// built — when every node is known to be of one kind: each level of a
    /// superclass chain is a class, each node of a refined protocol tree a
    /// protocol.
    func unresolvedTypes(assumingKind assumedKind: RuntimeRelationshipNode.TypeKind? = nil) -> OrderedSet<RuntimeRelationshipNode.UnresolvedType> {
        var types: OrderedSet<RuntimeRelationshipNode.UnresolvedType> = []
        for node in self {
            if let unresolvedType = node.unresolvedType(assumingKind: assumedKind) {
                types.append(unresolvedType)
            }
            types.append(contentsOf: node.children.unresolvedTypes(assumingKind: assumedKind))
        }
        return types
    }

    /// These nodes with each unresolved one that `resolvedTrees` has a tree
    /// for — by the node's name and kind — replaced by that tree: the type
    /// itself, its own ancestors underneath. `assumedKind` is as in
    /// `unresolvedTypes(assumingKind:)`, and the two calls must agree on it.
    func resolving(
        _ resolvedTrees: [RuntimeRelationshipNode.UnresolvedType: RuntimeRelationshipTree],
        assumingKind assumedKind: RuntimeRelationshipNode.TypeKind? = nil
    ) -> [RuntimeRelationshipNode] {
        map { node in
            if let unresolvedType = node.unresolvedType(assumingKind: assumedKind),
               let resolvedTree = resolvedTrees[unresolvedType] {
                return RuntimeRelationshipNode(object: resolvedTree.root, children: resolvedTree.nodes)
            }
            return node.replacingChildren(node.children.resolving(resolvedTrees, assumingKind: assumedKind))
        }
    }
}

extension RuntimeRelationshipNode {
    /// A type no image of the engine that built a node defines, as another
    /// engine looks it up: by name, and by kind when the kind is known — a
    /// class and a protocol may share a name, as `NSObject` does.
    struct UnresolvedType: Hashable, Sendable {
        let name: String
        let kind: TypeKind?
    }

    /// The type this node stands for when no image of the engine that built
    /// it defines one; `nil` for a resolved node. `assumedKind` is as in
    /// `unresolvedTypes(assumingKind:)`.
    func unresolvedType(assumingKind assumedKind: TypeKind? = nil) -> UnresolvedType? {
        guard object == nil else { return nil }
        return UnresolvedType(name: name, kind: typeKind ?? assumedKind)
    }
}
