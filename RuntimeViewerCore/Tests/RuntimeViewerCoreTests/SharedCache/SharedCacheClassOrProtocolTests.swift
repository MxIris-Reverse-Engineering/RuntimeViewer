#if os(macOS) && arch(arm64)

import Foundation
import ObjectiveC
import Testing
@testable import RuntimeViewerCore

/// A subclass of `NSObject` this test bundle defines, for a borrowing engine
/// to ask the superclass of.
final class SharedCacheClassOrProtocolFixtureObject: NSObject {}

/// A class and a protocol may share a name — `NSObject` is both — and an
/// engine that borrows shared cache images resolves the types its own images
/// do not define by name, through the images' owners. A superclass must come
/// back as the class, never as the protocol.
///
/// Each test makes its own pair of engines, in the test process: the owner
/// indexes libdispatch, which carries a copy of the `NSObject` protocol, but
/// not libobjc, which defines the `NSObject` class. That is how "My Mac" stood
/// when the Inspector of "My Mac (Mac Catalyst)" listed AppKit's `NSObject`
/// protocol as the superclass of `UIAnimator`.
///
/// The borrower's classes come from two images outside the shared cache: a
/// Swift subclass this test bundle defines, and `XCTestExpectation`, an
/// Objective-C class of the XCTest image the test process loads. Only the
/// Objective-C class's Ancestor Types names its superclass plainly
/// `NSObject`; the Swift class's names it `__C.NSObject`.
@Suite("Shared cache: a class is not the protocol of its name", .serialized)
struct SharedCacheClassOrProtocolTests {
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// Carries the `NSObject` protocol, which its `OS_dispatch_object`
    /// protocols refine, and is small to index.
    private static let protocolCarrierPath = "/usr/lib/system/libdispatch.dylib"

    /// This test bundle's image.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    /// An Objective-C class whose superclass is `NSObject`, defined outside
    /// the shared cache.
    private static let objcClassName = "XCTestExpectation"

    private struct Engines {
        let borrower: RuntimeEngine
        let owner: RuntimeEngine
    }

    private struct SetupError: Error {}

    /// A borrower that has indexed `borrowerImagePath`, and its owner, which
    /// has indexed the protocol carrier and not libobjc.
    private static func makeEngines(named name: String, indexingOnBorrower borrowerImagePath: String) async throws -> Engines {
        guard let partition = RuntimeSharedCachePartition.current() else { throw SetupError() }
        let owner = RuntimeEngine(source: .local, engineID: "shared-cache-class-or-protocol.\(name).owner")
        try await owner.connect()
        let borrower = RuntimeEngine(source: .local, engineID: "shared-cache-class-or-protocol.\(name).borrower")
        try await borrower.connect()
        await borrower.setSharedCacheOwners(RuntimeSharedCacheOwners(partition: partition, macOS: owner, macCatalyst: nil))
        let carrierObjects = try await borrower.objects(in: protocolCarrierPath)
        _ = try await borrower.objects(in: borrowerImagePath)

        // The situation the tests are about: the owner has the protocol and
        // not the class.
        try #require(carrierObjects.contains { $0.name == "NSObject" && $0.kind == .objc(.type(.protocol)) })
        try #require(try await !owner.indexedImagePathList().contains(libobjcPath))
        return Engines(borrower: borrower, owner: owner)
    }

    /// The image that defines `objcClassName`, which must not be in the
    /// shared cache.
    private static func objcClassImagePath() throws -> String {
        let objcClass: AnyClass = try #require(NSClassFromString(objcClassName), "\(objcClassName) is not loaded in the test process")
        let imagePath = try #require(class_getImageName(objcClass).map { String(cString: $0) })
        try #require(!DyldUtilities.isInDyldSharedCache(imagePath))
        return imagePath
    }

    private static func object(in imagePath: String, of engine: RuntimeEngine, where isWanted: (RuntimeObject) -> Bool) async throws -> RuntimeObject {
        try #require(try await engine.objects(in: imagePath).first(where: isWanted))
    }

    private static func expectLibobjcNSObjectClass(_ superclass: RuntimeRelationshipNode?, owner: RuntimeEngine) async throws {
        let superclass = try #require(superclass)
        #expect(superclass.name == "NSObject")
        #expect(superclass.object?.kind == .objc(.type(.class)))
        #expect(superclass.object?.imagePath == libobjcPath)
        #expect(try await owner.indexedImagePathList().contains(libobjcPath))
    }

    @Test("A Swift class's borrowed superclass is the class, from the image that defines it, which its owner indexes")
    func swiftSuperclassChainResolvesTheClass() async throws {
        let engines = try await Self.makeEngines(named: "swift-superclass-chain", indexingOnBorrower: Self.testBundlePath)
        let fixtureClass = try await Self.object(in: Self.testBundlePath, of: engines.borrower) {
            $0.kind == .swift(.type(.class)) && $0.displayName.hasSuffix("SharedCacheClassOrProtocolFixtureObject")
        }

        let chain = try await engines.borrower.superclassChain(for: fixtureClass)

        try await Self.expectLibobjcNSObjectClass(chain.first, owner: engines.owner)
    }

    @Test("An Objective-C class's borrowed superclass is the class, from the image that defines it, which its owner indexes")
    func objcSuperclassChainResolvesTheClass() async throws {
        let imagePath = try Self.objcClassImagePath()
        let engines = try await Self.makeEngines(named: "objc-superclass-chain", indexingOnBorrower: imagePath)
        let objcClass = try await Self.object(in: imagePath, of: engines.borrower) {
            $0.kind == .objc(.type(.class)) && $0.name == Self.objcClassName
        }

        let chain = try await engines.borrower.superclassChain(for: objcClass)

        try await Self.expectLibobjcNSObjectClass(chain.first, owner: engines.owner)
    }

    @Test("Ancestor Types never shows a borrowed superclass as the protocol of its name")
    func ancestorTreeKeepsTheSuperclassAClass() async throws {
        let imagePath = try Self.objcClassImagePath()
        let engines = try await Self.makeEngines(named: "ancestors", indexingOnBorrower: imagePath)

        let trees = try await engines.borrower.typeRelationships(.init(text: Self.objcClassName, relationship: .ancestors))

        let classTree = try #require(trees.first { $0.root.name == Self.objcClassName && $0.root.imagePath == imagePath })
        // An Objective-C class's ancestors are the protocols it adopts, then
        // its superclass.
        let superclass = try #require(classTree.nodes.last)
        #expect(superclass.name == "NSObject")
        #expect(superclass.object?.kind != .objc(.type(.protocol)), "the superclass became the protocol of \(superclass.object?.imagePath ?? "no image")")
    }
}

#endif
