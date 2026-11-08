#if os(macOS) && arch(arm64)

import Foundation
import Testing
import Combine
@testable import RuntimeViewerCore

/// An engine given shared cache owners hands every request about one of the
/// cache's images to the image's owner, and keeps serving the rest itself.
///
/// Both engines here run in the test process, so they read the same images;
/// which engine built an image's sections is what tells them apart.
@Suite("Shared cache routing", .serialized)
struct SharedCacheRoutingTests {
    private static let sharedCacheImagePath = "/usr/lib/libobjc.A.dylib"

    private static let macCatalystImagePath = "/System/iOSSupport/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore"

    /// The test process's own executable: outside the shared cache, and
    /// small enough to index quickly.
    private static let ownImagePath = DyldUtilities.mainExecutablePath()

    private struct Engines {
        let borrower: RuntimeEngine
        let owner: RuntimeEngine
        let owners: RuntimeSharedCacheOwners

        func stop() async {
            await borrower.stop()
            await owner.stop()
        }
    }

    private static func makeEngines(label: String) async throws -> Engines {
        let partition = try #require(RuntimeSharedCachePartition.current())
        let owner = RuntimeEngine(source: .local, engineID: "shared-cache-routing.\(label).owner")
        try await owner.connect()
        let borrower = RuntimeEngine(source: .local, engineID: "shared-cache-routing.\(label).borrower")
        try await borrower.connect()
        let owners = RuntimeSharedCacheOwners(partition: partition, macOS: owner, macCatalyst: nil)
        await borrower.setSharedCacheOwners(owners)
        return Engines(borrower: borrower, owner: owner, owners: owners)
    }

    private final class Recorder<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()

        private var recordedValues: [Value] = []

        private var subscription: AnyCancellable?

        init(listeningTo publisher: some Publisher<Value, Never>) {
            subscription = publisher.sink { [weak self] value in
                guard let self else { return }
                lock.lock()
                defer { lock.unlock() }
                recordedValues.append(value)
            }
        }

        var values: [Value] {
            lock.lock()
            defer { lock.unlock() }
            return recordedValues
        }
    }

    @Test("A shared cache image's objects are listed by its owner, which builds its sections")
    func sharedCacheImageGoesToItsOwner() async throws {
        let engines = try await Self.makeEngines(label: "shared-cache-image")

        let objects = try await engines.borrower.objects(in: Self.sharedCacheImagePath)

        #expect(objects.contains { $0.name == "NSObject" })
        #expect(await engines.owner._isImageIndexed(path: Self.sharedCacheImagePath))
        #expect(await !engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath))
        await engines.stop()
    }

    @Test("An image outside the shared cache stays with the engine it was asked of")
    func ownImageStaysWithTheBorrower() async throws {
        let engines = try await Self.makeEngines(label: "own-image")

        _ = try await engines.borrower.objects(in: Self.ownImagePath)

        #expect(await engines.borrower._isImageIndexed(path: Self.ownImagePath))
        #expect(await !engines.owner._isImageIndexed(path: Self.ownImagePath))
        await engines.stop()
    }

    @Test("Asked whether a shared cache image is indexed, the borrower answers for its owner")
    func indexedStateComesFromTheOwner() async throws {
        let engines = try await Self.makeEngines(label: "indexed-state")
        _ = try await engines.owner.objects(in: Self.sharedCacheImagePath)

        #expect(try await engines.borrower.isImageIndexed(path: Self.sharedCacheImagePath))
        await engines.stop()
    }

    @Test("The owner announces the image a borrowed request indexed")
    func ownerAnnouncesBorrowedIndexing() async throws {
        let engines = try await Self.makeEngines(label: "owner-announces")
        let ownerAnnouncements = Recorder(listeningTo: engines.owner.imageDidIndexPublisher)

        _ = try await engines.borrower.objects(in: Self.sharedCacheImagePath)

        #expect(ownerAnnouncements.values.contains(Self.sharedCacheImagePath))
        await engines.stop()
    }

    @Test("Loading a shared cache image loads it in its owner and reloads the borrower's observers")
    func loadingABorrowedImage() async throws {
        let engines = try await Self.makeEngines(label: "load")
        let borrowerChanges = Recorder(listeningTo: engines.borrower.dataChangePublisher)

        try await engines.borrower.loadImage(at: Self.sharedCacheImagePath)

        #expect(await engines.owner._isImageIndexed(path: Self.sharedCacheImagePath))
        #expect(await !engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath))
        #expect(try await engines.borrower.isImageLoaded(path: Self.sharedCacheImagePath))
        #expect(borrowerChanges.values.contains(.fullReload(isReloadImageNodes: false)))
        await engines.stop()
    }

    @Test("Loading into the serving process loads there even for a shared cache image")
    func loadingIntoTheServingProcess() async throws {
        let engines = try await Self.makeEngines(label: "load-in-serving-process")

        try await engines.borrower.loadImageInServingProcess(at: Self.sharedCacheImagePath)

        #expect(await engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath))
        #expect(await !engines.owner._isImageIndexed(path: Self.sharedCacheImagePath))
        await engines.stop()
    }

    @Test("An engine that owns an image serves the requests about it itself")
    func ownerServesItself() async throws {
        let engines = try await Self.makeEngines(label: "owner-serves-itself")
        await engines.owner.setSharedCacheOwners(engines.owners)

        _ = try await engines.owner.objects(in: Self.sharedCacheImagePath)

        #expect(await engines.owner._isImageIndexed(path: Self.sharedCacheImagePath))
        await engines.stop()
    }

    @Test("Without owners an engine serves every image again")
    func clearingTheOwners() async throws {
        let engines = try await Self.makeEngines(label: "cleared")
        await engines.borrower.setSharedCacheOwners(nil)

        _ = try await engines.borrower.objects(in: Self.sharedCacheImagePath)

        #expect(await engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath))
        #expect(await !engines.owner._isImageIndexed(path: Self.sharedCacheImagePath))
        await engines.stop()
    }

    @Test("Only the shared cache images an owner keeps are borrowed")
    func whichImagesAreBorrowed() async throws {
        let engines = try await Self.makeEngines(label: "which-images")

        #expect(engines.borrower.borrowsSharedCacheImage(at: Self.sharedCacheImagePath))
        #expect(!engines.borrower.borrowsSharedCacheImage(at: Self.ownImagePath))
        // No Mac Catalyst engine was given, so its images stay put.
        #expect(!engines.borrower.borrowsSharedCacheImage(at: Self.macCatalystImagePath))
        await engines.stop()
    }

    @Test("A stopped engine lets its owners go")
    func stoppingLetsTheOwnersGo() async throws {
        let engines = try await Self.makeEngines(label: "stopped")

        await engines.borrower.stop()

        #expect(engines.borrower.sharedCacheOwners == nil)
        await engines.owner.stop()
    }
}

#endif
