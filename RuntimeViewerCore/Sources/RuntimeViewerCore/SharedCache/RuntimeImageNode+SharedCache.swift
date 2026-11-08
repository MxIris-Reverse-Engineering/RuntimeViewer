import Foundation

extension RuntimeImageNode {
    /// The paths of every image under this node: what a tree of the shared cache is compared by
    /// before it is replaced with the partition's.
    var leafImagePaths: Set<String> {
        var imagePaths: Set<String> = []
        var pendingNodes = [self]
        while let node = pendingNodes.popLast() {
            if node.isLeaf {
                imagePaths.insert(node.path)
            } else {
                pendingNodes.append(contentsOf: node.children)
            }
        }
        return imagePaths
    }
}
