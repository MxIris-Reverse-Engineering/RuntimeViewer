import Testing
import RuntimeViewerCore

/// A Swift class whose superclass is a generic class bound to arguments
/// reaches that generic class in Ancestor Types, and is listed among its
/// subclasses in Descendent Types and in the Inspector.
///
/// The superclass is recorded under the name it is bound under
/// (`IncrementalUpdateAction<Menu, MenuItem>`), while the type tables know
/// the generic class by its own name; the two never met, so the chain broke
/// off at an unresolved leaf and the generic class listed no subclass.
@Suite("Relationships through a bound generic superclass", .serialized)
struct RuntimeTypeRelationshipsGenericSuperclassTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static func makeEngine(_ label: String) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-generic-superclass-" + label)
        try await engine.connect()
        try await engine.loadImage(at: appKitPath)
        return engine
    }

    private static func everyObject(of objects: [RuntimeObject]) -> [RuntimeObject] {
        objects.flatMap { object in [object] + everyObject(of: object.children) }
    }

    private static func ownName(of object: RuntimeObject) -> String {
        object.displayName.components(separatedBy: ".").last ?? object.displayName
    }

    /// `UpdateMenuAction: IncrementalUpdateAction<Menu, MenuItem>`, both
    /// AppKit's own Swift classes on macOS 26.7 and 27.0. AppKit-internal,
    /// so they are required rather than assumed.
    private static func anchors(in engine: RuntimeEngine) async throws -> (subclass: RuntimeObject, genericSuperclass: RuntimeObject) {
        let swiftClasses = everyObject(of: try await engine.objects(in: appKitPath)).filter { $0.kind == .swift(.type(.class)) }
        let subclass = try #require(swiftClasses.first { ownName(of: $0) == "UpdateMenuAction" }, "AppKit no longer has UpdateMenuAction")
        let genericSuperclass = try #require(
            swiftClasses.first { ownName(of: $0) == "IncrementalUpdateAction" || ownName(of: $0).hasPrefix("IncrementalUpdateAction<") },
            "AppKit no longer has IncrementalUpdateAction"
        )
        return (subclass, genericSuperclass)
    }

    @Test("Ancestor Types reach the generic class a bound superclass instantiates")
    func ancestorsReachTheGenericSuperclass() async throws {
        let engine = try await Self.makeEngine("ancestors")
        let (subclass, genericSuperclass) = try await Self.anchors(in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "UpdateMenuAction", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root == subclass })

        // Before: an unresolved leaf named after the bound superclass, with
        // nothing above it.
        let superclassNode = try #require(tree.nodes.first { $0.name.contains("IncrementalUpdateAction") }, "\(tree.nodes.map(\.name))")
        #expect(superclassNode.object == genericSuperclass, "\(superclassNode.name) is unresolved")
    }

    @Test("the generic class lists the subclass, in Descendent Types and in the Inspector")
    func genericSuperclassListsTheSubclass() async throws {
        let engine = try await Self.makeEngine("descendants")
        let (subclass, genericSuperclass) = try await Self.anchors(in: engine)

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "IncrementalUpdateAction", matchMode: .matchingWord, relationship: .descendants, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root == genericSuperclass })
        #expect(tree.nodes.contains { $0.object == subclass }, "\(tree.nodes.map(\.name))")

        // The Inspector reads the same subclass table; before, it missed the
        // subclass on main as well.
        let inspectorSubclasses = try await engine.relationships(for: genericSuperclass).subclasses
        #expect(inspectorSubclasses.contains(subclass), "\(inspectorSubclasses.map(\.displayName))")
    }

    /// Guards the Objective-C fallback the fix rewrote: a superclass no Swift
    /// table knows is looked up as an Objective-C class by the runtime name
    /// the indexer recorded for an imported class, no longer by the last
    /// component of its printed name. `NSScrollPocket: NSView` on macOS 26.7
    /// and 27.0.
    @Test("a Swift class reaches its imported Objective-C superclass")
    func swiftClassReachesItsImportedObjCSuperclass() async throws {
        let engine = try await Self.makeEngine("objc-superclass")
        let swiftClasses = Self.everyObject(of: try await engine.objects(in: Self.appKitPath)).filter { $0.kind == .swift(.type(.class)) }
        let scrollPocket = try #require(swiftClasses.first { $0.displayName == "AppKit.NSScrollPocket" }, "AppKit no longer has NSScrollPocket")

        let trees = try await engine.typeRelationships(RuntimeTypeRelationshipsQuery(text: "NSScrollPocket", matchMode: .matchingWord, relationship: .ancestors, isCaseSensitive: true))
        let tree = try #require(trees.first { $0.root == scrollPocket })

        let superclassNode = try #require(tree.nodes.first { $0.name.hasSuffix("NSView") }, "\(tree.nodes.map(\.name))")
        #expect(superclassNode.object?.kind == .objc(.type(.class)))
        #expect(superclassNode.object?.name == "NSView")
        #expect(superclassNode.children.contains { $0.name == "NSResponder" })
    }
}
