import Testing
import Foundation
import RuntimeViewerCore

@Suite("RuntimeImageNode")
struct RuntimeImageNodeTests {
    // MARK: - Initialization

    @Test("init sets name and defaults")
    func initDefaults() {
        let node = RuntimeImageNode("Root")
        #expect(node.name == "Root")
        #expect(node.parent == nil)
        #expect(node.children.isEmpty)
        #expect(node.isLeaf == true)
    }

    @Test("init with parent sets parent reference")
    func initWithParent() {
        let parent = RuntimeImageNode("Parent")
        let child = RuntimeImageNode("Child", parent: parent)
        #expect(child.parent === parent)
    }

    // MARK: - absolutePath

    @Test("absolutePath for root node starts with /")
    func absolutePathRoot() {
        let root = RuntimeImageNode("root")
        #expect(root.absolutePath == "/root")
    }

    @Test("absolutePath builds full path from parent chain")
    func absolutePathChain() {
        let root = RuntimeImageNode("System")
        let lib = RuntimeImageNode("Library", parent: root)
        let frameworks = RuntimeImageNode("Frameworks", parent: lib)
        #expect(frameworks.absolutePath == "/System/Library/Frameworks")
    }

    // MARK: - path

    @Test("path removes first component from absolutePath")
    func pathRemovesFirstComponent() {
        let root = RuntimeImageNode("System")
        let lib = RuntimeImageNode("Library", parent: root)
        let frameworks = RuntimeImageNode("Frameworks", parent: lib)
        // absolutePath = "/System/Library/Frameworks"
        // removeFirstPathComponent: "/Library/Frameworks"
        #expect(frameworks.path == "/Library/Frameworks")
    }

    // MARK: - isLeaf

    @Test("isLeaf is true for nodes without children")
    func isLeafTrue() {
        let node = RuntimeImageNode("Leaf")
        #expect(node.isLeaf == true)
    }

    @Test("isLeaf is false for nodes with children")
    func isLeafFalse() {
        let node = RuntimeImageNode("Parent")
        node.children = [RuntimeImageNode("Child", parent: node)]
        #expect(node.isLeaf == false)
    }

    // MARK: - child(named:)

    @Test("child(named:) creates new child if not exists")
    func childCreatesNew() {
        let root = RuntimeImageNode("root")
        let child = root.child(named: "usr")
        #expect(child.name == "usr")
        #expect(child.parent === root)
        #expect(root.children.count == 1)
        #expect(root.children[0] === child)
    }

    @Test("child(named:) returns existing child if already exists")
    func childReturnsExisting() {
        let root = RuntimeImageNode("root")
        let first = root.child(named: "usr")
        let second = root.child(named: "usr")
        #expect(first === second)
        #expect(root.children.count == 1)
    }

    @Test("child(named:) creates distinct children for different names")
    func childDistinct() {
        let root = RuntimeImageNode("root")
        let usr = root.child(named: "usr")
        let lib = root.child(named: "lib")
        #expect(usr !== lib)
        #expect(root.children.count == 2)
    }

    // MARK: - rootNode(for:)

    @Test("rootNode builds tree from single path")
    func rootNodeSinglePath() {
        let root = RuntimeImageNode.rootNode(for: ["/usr/lib/libobjc.A.dylib"])
        #expect(root.name == "")
        #expect(root.children.count == 1)
        #expect(root.children[0].name == "usr")

        let lib = root.children[0].children[0]
        #expect(lib.name == "lib")

        let dylib = lib.children[0]
        #expect(dylib.name == "libobjc.A.dylib")
        #expect(dylib.isLeaf == true)
    }

    @Test("rootNode builds tree from multiple paths sharing common prefix")
    func rootNodeMultiplePaths() {
        let root = RuntimeImageNode.rootNode(for: [
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/libSystem.B.dylib",
            "/usr/local/bin/tool",
        ])
        #expect(root.children.count == 1) // "usr"
        let usr = root.children[0]
        #expect(usr.name == "usr")
        #expect(usr.children.count == 2) // "lib" and "local"
    }

    @Test("rootNode handles multiple distinct root paths")
    func rootNodeDistinctRoots() {
        let root = RuntimeImageNode.rootNode(for: [
            "/System/Library/Frameworks/AppKit.framework/AppKit",
            "/usr/lib/libobjc.A.dylib",
        ])
        #expect(root.children.count == 2) // "System" and "usr"
    }

    @Test("rootNode with custom name")
    func rootNodeCustomName() {
        let root = RuntimeImageNode.rootNode(for: ["/a/b"], name: "CustomRoot")
        #expect(root.name == "CustomRoot")
    }

    @Test("rootNode handles dot path components")
    func rootNodeDotComponents() {
        let root = RuntimeImageNode.rootNode(for: ["/usr/./lib/test"])
        // "." should be skipped
        let usr = root.children[0]
        #expect(usr.name == "usr")
        #expect(usr.children[0].name == "lib")
    }

    @Test("rootNode handles dotdot path components")
    func rootNodeDotDotComponents() {
        let root = RuntimeImageNode.rootNode(for: ["/usr/local/../lib/test"])
        // "/usr/local/../lib/test" -> usr, then local, then back to usr, then lib, then test
        let usr = root.children[0]
        #expect(usr.name == "usr")
        // After ".." we go back to usr, then "lib" is a child of usr
        #expect(usr.children.contains(where: { $0.name == "lib" }))
    }

    @Test("rootNode with empty paths array")
    func rootNodeEmptyPaths() {
        let root = RuntimeImageNode.rootNode(for: [])
        #expect(root.children.isEmpty)
        #expect(root.isLeaf == true)
    }

    // MARK: - Codable

    @Test("encodes and decodes correctly")
    func codable() throws {
        let root = RuntimeImageNode("root")
        let child = RuntimeImageNode("child", parent: root)
        root.children = [child]
        // Trigger lazy absolutePath
        _ = root.absolutePath
        _ = child.absolutePath

        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(RuntimeImageNode.self, from: data)

        #expect(decoded.name == "root")
        #expect(decoded.children.count == 1)
        #expect(decoded.children[0].name == "child")
        #expect(decoded.children[0].parent === decoded) // parent restored
    }

    @Test("decoded nodes restore parent references")
    func codableParentRestored() throws {
        let root = RuntimeImageNode.rootNode(for: ["/a/b/c"])
        _ = root.absolutePath

        let data = try JSONEncoder().encode(root)
        let decoded = try JSONDecoder().decode(RuntimeImageNode.self, from: data)

        let a = decoded.children[0]
        let b = a.children[0]
        let c = b.children[0]

        #expect(a.parent === decoded)
        #expect(b.parent === a)
        #expect(c.parent === b)
    }

    // MARK: - Hashable / Equatable

    @Test("equal nodes have same hash")
    func hashEquality() {
        let a = RuntimeImageNode("test")
        let b = RuntimeImageNode("test")
        _ = a.absolutePath
        _ = b.absolutePath
        #expect(a == b)
        #expect(a.hashValue == b.hashValue)
    }

    @Test("different nodes are not equal")
    func hashInequality() {
        let a = RuntimeImageNode("foo")
        let b = RuntimeImageNode("bar")
        _ = a.absolutePath
        _ = b.absolutePath
        #expect(a != b)
    }
}
