#if os(macOS) && arch(arm64)

import Foundation
import Testing
@testable import RuntimeViewerCore

/// An Objective-C subclass this test bundle defines, of a class the shared
/// cache defines: what an attached process's own images hold.
final class SharedCacheSpanningFixtureObject: NSObject {}

/// Requests that reach across images, on an engine that borrows shared cache
/// images: the engine answers for its own images, the owner for the cache's,
/// and the answer is the two together.
///
/// The borrower indexes this test bundle, which is outside the shared cache,
/// and has the owner index libobjc; both engines run in the test process.
@Suite("Shared cache spanning", .serialized)
struct SharedCacheSpanningTests {
    private static let libobjcPath = "/usr/lib/libobjc.A.dylib"

    /// This test bundle's image.
    private static let testBundlePath: String = {
        var information = Dl_info()
        guard dladdr(#dsohandle, &information) != 0, let fileName = information.dli_fname else { return "" }
        return String(cString: fileName)
    }()

    private struct Engines: Sendable {
        let borrower: RuntimeEngine
        let owner: RuntimeEngine
    }

    private struct SetupError: Error {}

    /// One pair for the whole suite: indexing this test bundle takes seconds.
    private static let engines = Task<Engines, any Error> {
        guard let partition = RuntimeSharedCachePartition.current() else { throw SetupError() }
        let owner = RuntimeEngine(source: .local, engineID: "shared-cache-spanning.owner")
        try await owner.connect()
        let borrower = RuntimeEngine(source: .local, engineID: "shared-cache-spanning.borrower")
        try await borrower.connect()
        await borrower.setSharedCacheOwners(RuntimeSharedCacheOwners(partition: partition, macOS: owner, macCatalyst: nil))
        _ = try await borrower.objects(in: libobjcPath)
        _ = try await borrower.objects(in: testBundlePath)
        return Engines(borrower: borrower, owner: owner)
    }

    private static func object(named name: String, in imagePath: String, of engine: RuntimeEngine) async throws -> RuntimeObject {
        let objects = try await engine.objects(in: imagePath)
        return try #require(objects.first { $0.name == name || $0.displayName == name || $0.displayName.hasSuffix(".\(name)") })
    }

    @Test("The borrower's indexed images are its own and its owner's, each indexed once")
    func indexedImagesSpanBothEngines() async throws {
        let engines = try await Self.engines.value

        let borrowerImagePaths = try await engines.borrower.indexedImagePathList()
        let ownerImagePaths = try await engines.owner.indexedImagePathList()

        #expect(borrowerImagePaths.contains(Self.libobjcPath))
        #expect(borrowerImagePaths.contains(Self.testBundlePath))
        #expect(ownerImagePaths.contains(Self.libobjcPath))
        #expect(!ownerImagePaths.contains(Self.testBundlePath))
        #expect(await !engines.borrower._isImageIndexed(path: Self.libobjcPath))
    }

    @Test("A class's subclasses come from the borrower's images and the owner's")
    func relationshipsSpanBothEngines() async throws {
        let engines = try await Self.engines.value
        let rootClass = try await Self.object(named: "NSObject", in: Self.libobjcPath, of: engines.owner)

        let relationships = try await engines.borrower.relationships(for: rootClass)

        #expect(relationships.subclasses.contains { $0.name == "Protocol" && $0.imagePath == Self.libobjcPath })
        #expect(relationships.subclasses.contains { $0.imagePath == Self.testBundlePath && $0.displayName.contains("SharedCacheSpanningFixtureObject") })
    }

    @Test("A shared cache type's descendant tree carries the borrower's subclasses of it")
    func descendantTreesAreGrafted() async throws {
        let engines = try await Self.engines.value

        let trees = try await engines.borrower.typeRelationships(.init(text: "NSObject", relationship: .descendants))

        let rootTree = try #require(trees.first { $0.root.name == "NSObject" && $0.root.imagePath == Self.libobjcPath })
        #expect(rootTree.nodes.allObjects.contains { $0.imagePath == Self.testBundlePath && $0.displayName.contains("SharedCacheSpanningFixtureObject") })
    }

    @Test("The superclass chain of the borrower's own class resolves its shared cache superclass through the owner")
    func superclassChainIsRelayed() async throws {
        let engines = try await Self.engines.value
        let fixtureClass = try await Self.object(named: "SharedCacheSpanningFixtureObject", in: Self.testBundlePath, of: engines.borrower)

        let chain = try await engines.borrower.superclassChain(for: fixtureClass)

        let superclass = try #require(chain.first)
        #expect(superclass.object?.name == "NSObject")
        #expect(superclass.object?.imagePath == Self.libobjcPath)
    }

    @Test("An imported Objective-C reference is printed by the owner of the image that defines it")
    func importedReferenceIsPrintedByItsOwner() async throws {
        let engines = try await Self.engines.value
        let reference = RuntimeObject(name: "So8NSObjectC", displayName: "NSObject", kind: .swift(.type(.class)), imagePath: Self.testBundlePath, children: [])

        let interface = try await engines.borrower.interface(for: reference, options: .init())

        #expect(interface?.object.imagePath == Self.libobjcPath)
        #expect(await !engines.borrower._isImageIndexed(path: Self.libobjcPath))
    }

    @Test("A search is answered across the owner's corpora and held to the query's limit")
    func searchSpansAndHonoursTheLimit() async throws {
        let engines = try await Self.engines.value
        _ = try await engines.borrower.buildInterfaceCorpus(for: Self.libobjcPath, transformer: .init())

        let collector = MatchCollector()
        let summary = try await engines.borrower.searchInterfaces(.init(text: "NSObject", resultLimit: 1)) { matches in
            await collector.append(matches)
        }

        #expect(await collector.matches.count == 1)
        #expect(summary.isTruncated)
        #expect(summary.scannedImagePaths.contains(Self.libobjcPath))
    }

    private actor MatchCollector {
        private(set) var matches: [RuntimeInterfaceSearchMatch] = []

        func append(_ newMatches: [RuntimeInterfaceSearchMatch]) {
            matches += newMatches
        }
    }
}

#endif
