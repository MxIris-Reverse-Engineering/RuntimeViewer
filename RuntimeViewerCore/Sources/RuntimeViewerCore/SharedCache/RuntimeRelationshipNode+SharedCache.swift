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
            return RuntimeRelationshipNode(name: node.name, object: node.object, children: children)
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
            return RuntimeRelationshipNode(name: node.name, object: node.object, children: children)
        }
    }

    /// Every type the nodes hold, depth first.
    var allObjects: [RuntimeObject] {
        flatMap { node in
            (node.object.map { [$0] } ?? []) + node.children.allObjects
        }
    }

    /// The names of the nodes for types no image of the engine that built
    /// them defines, in the order they appear.
    var unresolvedNames: OrderedSet<String> {
        var names: OrderedSet<String> = []
        for node in self {
            if node.object == nil {
                names.append(node.name)
            }
            names.append(contentsOf: node.children.unresolvedNames)
        }
        return names
    }

    /// These nodes with each unresolved one that `resolvedTrees` has a tree
    /// for — by the node's name — replaced by that tree: the type itself, its
    /// own ancestors underneath.
    func resolving(_ resolvedTrees: [String: RuntimeRelationshipTree]) -> [RuntimeRelationshipNode] {
        map { node in
            if node.object == nil, let resolvedTree = resolvedTrees[node.name] {
                return RuntimeRelationshipNode(name: resolvedTree.root.displayName, object: resolvedTree.root, children: resolvedTree.nodes)
            }
            return RuntimeRelationshipNode(name: node.name, object: node.object, children: node.children.resolving(resolvedTrees))
        }
    }
}
