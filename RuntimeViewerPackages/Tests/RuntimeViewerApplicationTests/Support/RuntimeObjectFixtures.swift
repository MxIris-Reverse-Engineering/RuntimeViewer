import Foundation
import RuntimeViewerCore

/// Hand-built runtime objects and image trees for tests that do not need a
/// real engine. `sampleImagePath` is never loaded or indexed, so an engine
/// asked about one of these objects always takes its "unknown image" path.
enum Fixtures {
    static let sampleImagePath = "/System/Library/Frameworks/Sample.framework/Sample"

    static func runtimeObject(
        name: String = "Sample",
        displayName: String? = nil,
        kind: RuntimeObjectKind = .swift(.type(.class)),
        secondaryKind: RuntimeObjectKind? = nil,
        imagePath: String = sampleImagePath,
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: displayName ?? name,
            kind: kind,
            secondaryKind: secondaryKind,
            imagePath: imagePath,
            children: children,
            properties: properties
        )
    }

    /// An image tree with one synthetic root above the given absolute paths,
    /// the same shape `RuntimeEngine` publishes ("Dyld Shared Cache" / "Others").
    static func imageTree(rootName: String, imagePaths: [String]) -> RuntimeImageNode {
        RuntimeImageNode.rootNode(for: imagePaths, name: rootName)
    }
}

extension RuntimeImageNode {
    /// The leaf whose engine-facing `path` (root component stripped) equals `imagePath`.
    func leaf(forImagePath imagePath: String) -> RuntimeImageNode? {
        if isLeaf, path == imagePath { return self }
        for child in children {
            if let match = child.leaf(forImagePath: imagePath) { return match }
        }
        return nil
    }

    /// The first leaf (depth-first) named `name`, e.g. the binary inside a framework bundle.
    func leaf(named name: String) -> RuntimeImageNode? {
        if isLeaf, self.name == name { return self }
        for child in children {
            if let match = child.leaf(named: name) { return match }
        }
        return nil
    }
}
