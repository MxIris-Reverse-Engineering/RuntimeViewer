#if os(macOS) && arch(arm64)

import Foundation
import Testing
import Combine
@testable import RuntimeViewerCore

/// Every engine on this Mac's cache holds one tree of the cache's images: an engine given owners
/// replaces its copy of the tree with the partition's, and keeps a tree that lists other images.
@Suite("Shared cache image tree", .serialized)
struct SharedCacheImageTreeTests {
    private static func sharedCacheTree(of engine: RuntimeEngine) -> RuntimeImageNode? {
        engine.imageNodes.first { $0.name == RuntimeSharedCachePartition.imageRootNodeName }
    }

    /// The engine's image nodes, once it has published them.
    private static func publishedImageNodes(of engine: RuntimeEngine) async -> [RuntimeImageNode] {
        for await imageNodes in engine.imageNodesPublisher.values where !imageNodes.isEmpty {
            return imageNodes
        }
        return []
    }

    @Test("An engine given owners holds the partition's tree of the shared cache in place of its own copy")
    func ownersShareTheTree() async throws {
        let partition = try #require(RuntimeSharedCachePartition.current())
        let owner = RuntimeEngine(source: .local, engineID: "shared-cache-image-tree.owner")
        let borrower = RuntimeEngine(source: .local, engineID: "shared-cache-image-tree.borrower")
        try await borrower.connect()
        _ = await Self.publishedImageNodes(of: borrower)
        let ownTree = try #require(Self.sharedCacheTree(of: borrower))
        #expect(ownTree !== partition.imageRootNode)

        await borrower.setSharedCacheOwners(RuntimeSharedCacheOwners(partition: partition, macOS: owner, macCatalyst: nil))

        #expect(Self.sharedCacheTree(of: borrower) === partition.imageRootNode)
        await borrower.stop()
    }

    @Test("A tree that lists other images than the partition's is kept as it came")
    func anotherCachesTreeIsKept() throws {
        let partition = try #require(RuntimeSharedCachePartition.current())
        let owner = RuntimeEngine(source: .local, engineID: "shared-cache-image-tree.other.owner")
        let borrower = RuntimeEngine(source: .local, engineID: "shared-cache-image-tree.other.borrower")
        borrower.sharedCacheOwnersSubject.value = RuntimeSharedCacheOwners(partition: partition, macOS: owner, macCatalyst: nil)
        let otherTree = RuntimeImageNode.rootNode(for: ["/usr/lib/libOther.dylib"], name: RuntimeSharedCachePartition.imageRootNodeName)

        let imageNodes = borrower.sharingSharedCacheImageRoot(in: [otherTree])

        #expect(imageNodes.count == 1)
        #expect(imageNodes.first === otherTree)
    }
}

#endif
