import Testing
@testable import RuntimeViewerCore

/// The Inspector's class hierarchy: a class's superclasses as runtime objects,
/// nearest first, found across images and across the language boundary the
/// way Ancestor Types finds its superclass levels.
///
/// Anchored on AppKit's `NSButton: NSControl: NSView: NSResponder` and its
/// Swift class `NSScrollPocket: NSView` (macOS 26.7 and 27.0), both ending at
/// libobjc's `NSObject`.
@Suite("Superclass chain", .serialized)
struct RuntimeSuperclassChainTests {
    private static let appKitPath = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"

    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// AppKit and libobjc indexed: every level of the anchors' chains is
    /// defined somewhere the engine knows.
    private static let indexedEngine = Task<RuntimeEngine, Error> {
        try await makeEngine("indexed", loading: [libobjcPath, appKitPath])
    }

    private static func makeEngine(_ label: String, loading imagePaths: [String]) async throws -> RuntimeEngine {
        let engine = RuntimeEngine(source: .local, engineID: "test-superclass-chain-" + label)
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
    #endif
}
