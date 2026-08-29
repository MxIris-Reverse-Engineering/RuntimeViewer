import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

// MARK: - RuntimeImageBookmark Tests

@Suite("RuntimeImageBookmark")
struct RuntimeImageBookmarkTests {
    @Test("Initialization with imageNode")
    func initialization() {
        let bookmark = RuntimeImageBookmark(imageNode: RuntimeImageNode("libobjc.dylib"))
        #expect(bookmark.imageNode.name == "libobjc.dylib")
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = RuntimeImageBookmark(imageNode: RuntimeImageNode("Foundation"))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeImageBookmark.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip with complex image node tree")
    func codableWithTree() throws {
        let rootNode = RuntimeImageNode.rootNode(
            for: ["/usr/lib/libobjc.dylib", "/usr/lib/libSystem.dylib"],
            name: "Images"
        )

        let original = RuntimeImageBookmark(imageNode: rootNode)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeImageBookmark.self, from: data)
        #expect(decoded.imageNode.name == original.imageNode.name)
        #expect(decoded.imageNode.children.count == original.imageNode.children.count)
    }

    @Test("Bookmarking a deep leaf preserves its image path across a round-trip")
    func codableDeepLeafBookmark() throws {
        // Mirrors how bookmarks are created in the sidebar: a single leaf node lifted out of
        // the live tree, persisted on its own, and later read back with no ancestors around.
        let rootNode = RuntimeImageNode.rootNode(
            for: ["/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"],
            name: "Dyld Shared Cache"
        )
        var leafNode = rootNode
        while let next = leafNode.children.first { leafNode = next }

        let original = RuntimeImageBookmark(imageNode: leafNode)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeImageBookmark.self, from: data)

        #expect(decoded.imageNode.path == "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit")
        #expect(decoded.imageNode == original.imageNode)
    }

    @Test("A bookmark written before the source field was dropped still decodes")
    func decodesLegacyPayloadCarryingASource() throws {
        // Files on disk still carry the field. It has to decode as an ignored
        // extra key, or every bookmark the user has is unreadable after the
        // upgrade — the exact failure this whole change exists to prevent.
        let legacyJSON = """
        {"source": {"local": {}}, "imageNode": {"name": "AppKit", "absolutePath": "/AppKit", "children": []}}
        """
        let decoded = try JSONDecoder().decode(RuntimeImageBookmark.self, from: Data(legacyJSON.utf8))
        #expect(decoded.imageNode.name == "AppKit")
    }

    @Test("A bookmark no longer encodes a source of its own")
    func doesNotEncodeASource() throws {
        let data = try JSONEncoder().encode(RuntimeImageBookmark(imageNode: RuntimeImageNode("AppKit")))
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["source"] == nil)
        #expect(object.keys.sorted() == ["imageNode"])
    }
}

// MARK: - RuntimeObjectBookmark Tests

@Suite("RuntimeObjectBookmark")
struct RuntimeObjectBookmarkTests {
    private func makeObject(
        name: String,
        kind: RuntimeObjectKind = .objc(.type(.class)),
        imagePath: String = "/usr/lib/libobjc.dylib",
        children: [RuntimeObject] = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: name,
            displayName: name,
            kind: kind,
            secondaryKind: nil,
            imagePath: imagePath,
            children: children
        )
    }

    @Test("Initialization with object")
    func initialization() {
        let bookmark = RuntimeObjectBookmark(object: makeObject(name: "NSObject"))
        #expect(bookmark.object.name == "NSObject")
        #expect(bookmark.object.kind == .objc(.type(.class)))
    }

    @Test("Initialization with a Swift object")
    func initializationSwift() {
        let bookmark = RuntimeObjectBookmark(object: makeObject(
            name: "MyStruct",
            kind: .swift(.type(.struct)),
            imagePath: "/usr/lib/swift/libswiftCore.dylib"
        ))
        #expect(bookmark.object.kind == .swift(.type(.struct)))
    }

    @Test("Codable round-trip")
    func codable() throws {
        let original = RuntimeObjectBookmark(object: makeObject(
            name: "NSView",
            imagePath: "/System/Library/Frameworks/AppKit.framework/AppKit"
        ))
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeObjectBookmark.self, from: data)
        #expect(decoded == original)
    }

    @Test("Codable round-trip with children")
    func codableWithChildren() throws {
        let parentObject = makeObject(name: "ParentClass", children: [makeObject(name: "ChildClass")])

        let original = RuntimeObjectBookmark(object: parentObject)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeObjectBookmark.self, from: data)
        #expect(decoded.object.children.count == 1)
        #expect(decoded.object.children[0].name == "ChildClass")
    }

    @Test("A bookmark written before the source field was dropped still decodes")
    func decodesLegacyPayloadCarryingASource() throws {
        let legacyJSON = """
        {"source": {"bonjour": {"identifier": "DEV-100", "name": "SpringBoard", "role": {"client": {}}}}, \
        "object": {"children": [], "displayName": "NSObject", "imagePath": "/usr/lib/libobjc.dylib", \
        "kind": {"objc": {"_0": {"type": {"_0": {"class": {}}}}}}, "name": "NSObject", "properties": 0}}
        """
        let decoded = try JSONDecoder().decode(RuntimeObjectBookmark.self, from: Data(legacyJSON.utf8))
        #expect(decoded.object.name == "NSObject")
    }
}
