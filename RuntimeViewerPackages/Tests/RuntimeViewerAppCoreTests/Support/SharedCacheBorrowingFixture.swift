import Foundation
@testable import RuntimeViewerCore
import RuntimeViewerAppTestingSupport

/// Two in-process engines, the borrower borrowing from the owner through a
/// partition whose only shared cache image is libobjc — loaded in every test
/// process, so both engines list it as loaded. Foundation, outside the
/// partition, stays the borrower's own.
struct SharedCacheBorrowingFixture {
    let ownerEngine: RuntimeEngine
    let borrowerEngine: RuntimeEngine
    let owners: RuntimeSharedCacheOwners

    /// The image the borrower borrows.
    static let borrowedImagePath = TestImages.libobjc

    /// An image the borrower keeps itself.
    static let ownImagePath = TestImages.foundation

    /// The engines, the borrower already given its owner when `isBorrowing`.
    static func make(label: String, isBorrowing: Bool = true) async throws -> SharedCacheBorrowingFixture {
        let ownerEngine = try await TestRuntimeEngine.makeConnected(engineID: "SharedCacheBorrowing.\(label).owner")
        let borrowerEngine = try await TestRuntimeEngine.makeConnected(engineID: "SharedCacheBorrowing.\(label).borrower")
        let partition = RuntimeSharedCachePartition(cacheUUID: UUID(), orderedImagePaths: [borrowedImagePath], macCatalystOnlyImagePaths: [])
        let owners = RuntimeSharedCacheOwners(partition: partition, macOS: ownerEngine, macCatalyst: nil)
        if isBorrowing {
            await borrowerEngine.setSharedCacheOwners(owners)
        }
        return SharedCacheBorrowingFixture(ownerEngine: ownerEngine, borrowerEngine: borrowerEngine, owners: owners)
    }

    func stop() async {
        await borrowerEngine.stop()
        await ownerEngine.stop()
    }
}
