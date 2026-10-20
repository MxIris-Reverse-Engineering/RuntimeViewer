import Testing
@testable import RuntimeViewerCore

/// The Inspector's hierarchies: a class's superclasses as runtime objects,
/// nearest first, found across images and across the language boundary the
/// way Ancestor Types finds its superclass levels; and the tree of protocols a
/// protocol refines, which is Ancestor Types' own.
///
/// Anchored on AppKit's `NSButton: NSControl: NSView: NSResponder` and its
/// Swift class `NSScrollPocket: NSView`, both ending at libobjc's `NSObject`,
/// and on its protocols `NSTableViewDelegate <NSControlTextEditingDelegate>`
/// and the Swift `MenuItemBase` (macOS 26.7 and 27.0).
@Suite("Inspector hierarchy", .serialized)
struct RuntimeInspectorHierarchyTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// AppKit and libobjc indexed: every level of the anchors' chains is
    /// defined somewhere the engine knows.
    private static let indexedEngine = Task<RuntimeEngine, Error> {
        try await makeEngine("indexed", loading: [libobjcPath, appKitPath])
    }

    private static func makeEngine(_ label: String, loading imagePaths: [String]) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-inspector-hierarchy-" + label)
        try await engine.connect()
        for imagePath in imagePaths {
            try await engine.loadImage(at: imagePath)
        }
        return engine
    }

    private static func objcClass(named name: String, in imagePath: String, of engine: RuntimeEngine) async throws -> RuntimeObject {
        let objects = try await engine.objects(in: imagePath)
        return try #require(objects.first { $0.name == name && $0.kind == .objc(.type(.class)) }, "\(name) not found in \(imagePath)")
    }

    private static func everyObject(of objects: [RuntimeObject]) -> [RuntimeObject] {
        objects.flatMap { object in [object] + everyObject(of: object.children) }
    }

    @Test("an Objective-C class lists its superclasses nearest first, each from the image that defines it")
    func objcClassListsItsSuperclasses() async throws {
        let engine = try await Self.indexedEngine.value
        let button = try await Self.objcClass(named: "NSButton", in: Self.appKitPath, of: engine)
        let expectedSuperclasses: [RuntimeObject?] = try await [
            Self.objcClass(named: "NSControl", in: Self.appKitPath, of: engine),
            Self.objcClass(named: "NSView", in: Self.appKitPath, of: engine),
            Self.objcClass(named: "NSResponder", in: Self.appKitPath, of: engine),
            Self.objcClass(named: "NSObject", in: Self.libobjcPath, of: engine),
        ]

        let chain = try await engine.superclassChain(for: button)

        #expect(chain.map(\.object) == expectedSuperclasses, "\(chain.map(\.name))")
        #expect(chain.allSatisfy { $0.children.isEmpty })
    }

    @Test("a Swift class reaches its imported Objective-C superclass, and the chain goes on from there")
    func swiftClassReachesItsImportedObjCSuperclass() async throws {
        let engine = try await Self.indexedEngine.value
        let swiftClasses = Self.everyObject(of: try await engine.objects(in: Self.appKitPath)).filter { $0.kind == .swift(.type(.class)) }
        let scrollPocket = try #require(swiftClasses.first { $0.displayName == "AppKit.NSScrollPocket" }, "AppKit no longer has NSScrollPocket")
        let expectedSuperclasses: [RuntimeObject?] = try await [
            Self.objcClass(named: "NSView", in: Self.appKitPath, of: engine),
            Self.objcClass(named: "NSResponder", in: Self.appKitPath, of: engine),
            Self.objcClass(named: "NSObject", in: Self.libobjcPath, of: engine),
        ]

        let chain = try await engine.superclassChain(for: scrollPocket)

        #expect(chain.map(\.object) == expectedSuperclasses, "\(chain.map(\.name))")
    }

    /// `NSPersistentUIKeyedUnarchiver: NSKeyedUnarchiver: NSCoder: NSObject`
    /// (macOS 26.7 and 27.0): the two in the middle are Foundation's, which
    /// the engine has not indexed, and NSObject is libobjc's, which it has.
    @Test("the levels above a superclass no indexed image defines come from the class's own metadata, each resolved where it can be")
    func levelsAboveAnUnindexedSuperclassComeFromTheMetadata() async throws {
        let engine = try await Self.indexedEngine.value
        let unarchiver = try await Self.objcClass(named: "NSPersistentUIKeyedUnarchiver", in: Self.appKitPath, of: engine)
        let object = try await Self.objcClass(named: "NSObject", in: Self.libobjcPath, of: engine)

        let chain = try await engine.superclassChain(for: unarchiver)

        #expect(chain.map(\.name) == ["NSKeyedUnarchiver", "NSCoder", "NSObject"])
        #expect(chain.map(\.object) == [nil, nil, object])
    }

    /// `AppKit._MultiShadowLayer: CALayer` (macOS 26.7 and 27.0): CALayer is
    /// QuartzCore's, which the engine has not indexed.
    @Test("a Swift class's levels above a superclass no indexed image defines come from its Objective-C face")
    func swiftClassLevelsAboveAnUnindexedSuperclassComeFromItsObjCFace() async throws {
        let engine = try await Self.indexedEngine.value
        let swiftClasses = Self.everyObject(of: try await engine.objects(in: Self.appKitPath)).filter { $0.kind == .swift(.type(.class)) }
        let shadowLayer = try #require(swiftClasses.first { $0.displayName == "AppKit._MultiShadowLayer" }, "AppKit no longer has _MultiShadowLayer")
        let object = try await Self.objcClass(named: "NSObject", in: Self.libobjcPath, of: engine)

        let chain = try await engine.superclassChain(for: shadowLayer)

        #expect(chain.map(\.name) == ["CALayer", "NSObject"])
        #expect(chain.map(\.object) == [nil, object])
    }

    @Test(
        "a level known only by its Objective-C runtime name shows a Swift class's name demangled, any other as it is",
        arguments: [
            ("_TtC6AppKit17_MultiShadowLayer", "AppKit._MultiShadowLayer"),
            ("NSKeyedUnarchiver", "NSKeyedUnarchiver"),
        ]
    )
    func objcRuntimeNameIsShownDemangled(_ argument: (runtimeName: String, displayName: String)) {
        #expect(RuntimeTypeRelationshipsResolver.displayName(ofObjCClassNamed: argument.runtimeName) == argument.displayName)
    }

    @Test("a superclass no indexed image defines keeps its name, unresolved")
    func superclassOutsideTheIndexedImagesKeepsItsName() async throws {
        // libobjc is left out, so nothing the engine indexed defines NSObject.
        let engine = try await Self.makeEngine("appkit-only", loading: [Self.appKitPath])
        let button = try await Self.objcClass(named: "NSButton", in: Self.appKitPath, of: engine)

        let chain = try await engine.superclassChain(for: button)

        #expect(chain.map(\.name) == ["NSControl", "NSView", "NSResponder", "NSObject"])
        #expect(chain.dropLast().allSatisfy { $0.isResolved })
        #expect(chain.last?.isResolved == false)
    }

    @Test("a root class has no superclasses")
    func rootClassHasNoSuperclasses() async throws {
        let engine = try await Self.indexedEngine.value
        let object = try await Self.objcClass(named: "NSObject", in: Self.libobjcPath, of: engine)

        #expect(try await engine.superclassChain(for: object).isEmpty)
    }

    // MARK: - Refined Protocol Tree

    private static func objcProtocol(named name: String, in imagePath: String, of engine: RuntimeEngine) async throws -> RuntimeObject {
        let objects = try await engine.objects(in: imagePath)
        return try #require(objects.first { $0.name == name && $0.kind == .objc(.type(.protocol)) }, "\(name) not found in \(imagePath)")
    }

    @Test("an Objective-C protocol lists the protocols it refines, each with the ones it refines underneath")
    func objcProtocolListsItsRefinedProtocols() async throws {
        let engine = try await Self.indexedEngine.value
        let tableViewDelegate = try await Self.objcProtocol(named: "NSTableViewDelegate", in: Self.appKitPath, of: engine)

        let tree = try await engine.refinedProtocolTree(for: tableViewDelegate)

        #expect(tree.map(\.name) == ["NSControlTextEditingDelegate"])
        let textEditingDelegate = try #require(tree.first)
        #expect(textEditingDelegate.object?.kind == .objc(.type(.protocol)))
        #expect(textEditingDelegate.children.map(\.name) == ["NSObject"])
        #expect(textEditingDelegate.children.first?.object?.kind == .objc(.type(.protocol)))
    }

    /// `MenuItemBase: XPCCodable, Decodable, Encodable, Identifiable`: the
    /// first is AppKit's own, the rest are the standard library's, which the
    /// engine has not indexed.
    @Test("a Swift protocol lists the protocols it refines, those no indexed image defines by name")
    func swiftProtocolListsItsRefinedProtocols() async throws {
        let engine = try await Self.indexedEngine.value
        let swiftProtocols = Self.everyObject(of: try await engine.objects(in: Self.appKitPath)).filter { $0.kind == .swift(.type(.protocol)) }
        let menuItemBase = try #require(swiftProtocols.first { $0.displayName == "AppKit.MenuItemBase" }, "AppKit no longer has MenuItemBase")

        let tree = try await engine.refinedProtocolTree(for: menuItemBase)

        #expect(Set(tree.map(\.name)) == ["AppKit.XPCCodable", "Swift.Decodable", "Swift.Encodable", "Swift.Identifiable"])
        #expect(tree.first { $0.name == "AppKit.XPCCodable" }?.object?.kind == .swift(.type(.protocol)))
        #expect(tree.filter { $0.name.hasPrefix("Swift.") }.allSatisfy { $0.object == nil })
    }

    @Test("anything but a protocol has no refined protocol tree")
    func classHasNoRefinedProtocolTree() async throws {
        let engine = try await Self.indexedEngine.value
        let button = try await Self.objcClass(named: "NSButton", in: Self.appKitPath, of: engine)

        #expect(try await engine.refinedProtocolTree(for: button).isEmpty)
    }

    #if canImport(Network) && os(macOS)
    @Test("a caller reaches the chain through a connection", arguments: RemoteEnginePair.Transport.allCases)
    func chainCrossesAConnection(transport: RemoteEnginePair.Transport) async throws {
        let serving = try await Self.indexedEngine.value
        let button = try await Self.objcClass(named: "NSButton", in: Self.appKitPath, of: serving)
        let localChain = try await serving.superclassChain(for: button)
        let pair = try await RemoteEnginePair.make(transport, label: "superclass-chain.\(transport)", serving: serving)

        let forwardedChain = try await pair.client.superclassChain(for: button)
        await pair.stop()

        #expect(!localChain.isEmpty)
        #expect(forwardedChain == localChain)
    }

    @Test("a caller reaches the refined protocol tree through a connection", arguments: RemoteEnginePair.Transport.allCases)
    func refinedProtocolTreeCrossesAConnection(transport: RemoteEnginePair.Transport) async throws {
        let serving = try await Self.indexedEngine.value
        let tableViewDelegate = try await Self.objcProtocol(named: "NSTableViewDelegate", in: Self.appKitPath, of: serving)
        let localTree = try await serving.refinedProtocolTree(for: tableViewDelegate)
        let pair = try await RemoteEnginePair.make(transport, label: "refined-protocol-tree.\(transport)", serving: serving)

        let forwardedTree = try await pair.client.refinedProtocolTree(for: tableViewDelegate)
        await pair.stop()

        #expect(!localTree.isEmpty)
        #expect(forwardedTree == localTree)
    }
    #endif
}
