import RuntimeViewerCore

extension RuntimeImageNode {
    /// The node's path as the image list shows it: the names of the node and of
    /// its ancestors below the tree's root, joined by `/`. The root itself — a
    /// group such as "Dyld Shared Cache" or "Frameworks", or the folder a file
    /// engine opened — is left out, so a tree that starts below `/` gives a path
    /// relative to where it starts. A bookmarked image, kept apart from its tree,
    /// gives its own name; a root gives an empty path.
    ///
    /// Copy Path puts this on the pasteboard, Copy Full Path the node's `path`.
    public var displayedPath: String {
        var names: [String] = []
        var currentNode: RuntimeImageNode? = self
        while let node = currentNode, node.parent != nil {
            names.append(node.name)
            currentNode = node.parent
        }
        if names.isEmpty, isLeaf {
            return name
        }
        return names.reversed().joined(separator: "/")
    }

    /// The node's whole path when it names somewhere on disk: an image, or a
    /// folder below the root; a root only when it stands for a folder, as the
    /// one a file engine opened does. `nil` for a root that only groups its
    /// children, whose `path` is `/`.
    public var fullPath: String? {
        let path = path
        return path.isEmpty || path == "/" ? nil : path
    }
}
