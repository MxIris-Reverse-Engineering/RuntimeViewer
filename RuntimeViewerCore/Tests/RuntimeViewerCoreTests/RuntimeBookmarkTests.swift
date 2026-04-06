import Testing
import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

// MARK: - RuntimeImageBookmark Tests

@Suite("RuntimeImageBookmark")
struct RuntimeImageBookmarkTests {
    @Test("Initialization with source and imageNode")
    func initialization() {
        let source = RuntimeSource.local
        let imageNode = RuntimeImageNode("libobjc.dylib")

        let bookmark = RuntimeImageBookmark(source: source, imageNode: imageNode)
        #expect(bookmark.source == source)
        #expect(bookmark.imageNode.name == "libobjc.dylib")
    }

    @Test("Initialization with remote source")
    func initializationWithRemoteSource() {
        let source = RuntimeSource.remote(name: "Device", identifier: "abc-123", role: .server)
        let imageNode = RuntimeImageNode("UIKit")

        let bookmark = RuntimeImageBookmark(source: source, imageNode: imageNode)
        #expect(bookmark.source == source)
        #expect(bookmark.imageNode.name == "UIKit")
    }

    @Test("Codable round-trip")
    func codable() throws {
        let source = RuntimeSource.local
        let imageNode = RuntimeImageNode("Foundation")

        let original = RuntimeImageBookmark(source: source, imageNode: imageNode)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeImageBookmark.self, from: data)
        #expect(decoded.source == original.source)
        #expect(decoded.imageNode == original.imageNode)
    }

    @Test("Codable round-trip with complex image node tree")
    func codableWithTree() throws {
        let rootNode = RuntimeImageNode.rootNode(
            for: ["/usr/lib/libobjc.dylib", "/usr/lib/libSystem.dylib"],
            name: "Images"
        )
        let source = RuntimeSource.bonjour(name: "TestDevice", identifier: "test-id", role: .client)

        let original = RuntimeImageBookmark(source: source, imageNode: rootNode)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeImageBookmark.self, from: data)
        #expect(decoded.source == original.source)
        #expect(decoded.imageNode.name == original.imageNode.name)
        #expect(decoded.imageNode.children.count == original.imageNode.children.count)
    }
}

// MARK: - RuntimeObjectBookmark Tests

@Suite("RuntimeObjectBookmark")
struct RuntimeObjectBookmarkTests {
    @Test("Initialization with source and object")
    func initialization() {
        let source = RuntimeSource.local
        let object = RuntimeObject(
            name: "NSObject",
            displayName: "NSObject",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/usr/lib/libobjc.dylib",
            children: []
        )

        let bookmark = RuntimeObjectBookmark(source: source, object: object)
        #expect(bookmark.source == source)
        #expect(bookmark.object.name == "NSObject")
        #expect(bookmark.object.kind == .objc(.type(.class)))
    }

    @Test("Initialization with Swift object and remote source")
    func initializationSwiftRemote() {
        let source = RuntimeSource.directTCP(name: "Remote", host: "192.168.1.1", port: 8080, role: .server)
        let object = RuntimeObject(
            name: "MyStruct",
            displayName: "MyStruct",
            kind: .swift(.type(.struct)),
            secondaryKind: nil,
            imagePath: "/usr/lib/swift/libswiftCore.dylib",
            children: []
        )

        let bookmark = RuntimeObjectBookmark(source: source, object: object)
        #expect(bookmark.source == source)
        #expect(bookmark.object.kind == .swift(.type(.struct)))
    }

    @Test("Codable round-trip")
    func codable() throws {
        let source = RuntimeSource.local
        let object = RuntimeObject(
            name: "NSView",
            displayName: "NSView",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/AppKit.framework/AppKit",
            children: []
        )

        let original = RuntimeObjectBookmark(source: source, object: object)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeObjectBookmark.self, from: data)
        #expect(decoded.source == original.source)
        #expect(decoded.object == original.object)
    }

    @Test("Codable round-trip with children")
    func codableWithChildren() throws {
        let childObject = RuntimeObject(
            name: "ChildClass",
            displayName: "ChildClass",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/usr/lib/libobjc.dylib",
            children: []
        )
        let parentObject = RuntimeObject(
            name: "ParentClass",
            displayName: "ParentClass",
            kind: .objc(.type(.class)),
            secondaryKind: nil,
            imagePath: "/usr/lib/libobjc.dylib",
            children: [childObject]
        )
        let source = RuntimeSource.localSocket(name: "Socket", identifier: "sock-1", role: .server)

        let original = RuntimeObjectBookmark(source: source, object: parentObject)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RuntimeObjectBookmark.self, from: data)
        #expect(decoded.object.children.count == 1)
        #expect(decoded.object.children[0].name == "ChildClass")
    }
}
