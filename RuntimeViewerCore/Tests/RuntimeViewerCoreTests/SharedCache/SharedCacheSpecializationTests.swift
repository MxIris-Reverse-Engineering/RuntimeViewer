#if os(macOS) && arch(arm64)

import Foundation
import Testing
import Combine
@testable import RuntimeViewerCore

/// Specializing with borrowed shared cache images. A type of the engine's own
/// images is specialized in its serving process, whose candidates are the
/// types it has indexed, so the borrowed images it has loaded are indexed
/// there first, once. A specialization the owner registers for a borrowed
/// image is announced on the borrower too.
@Suite("Shared cache specialization", .serialized)
struct SharedCacheSpecializationTests {
    private static let sharedCacheImagePath = "/usr/lib/libobjc.A.dylib"

    /// The test process's own executable: outside the shared cache.
    private static let ownImagePath = DyldUtilities.mainExecutablePath()

    private struct Engines {
        let borrower: RuntimeEngine
        let owner: RuntimeEngine

        func stop() async {
            await borrower.stop()
            await owner.stop()
        }
    }

    private static func makeEngines(label: String) async throws -> Engines {
        let partition = try #require(RuntimeSharedCachePartition.current())
        let owner = RuntimeEngine(source: .local, engineID: "shared-cache-specialization.\(label).owner")
        try await owner.connect()
        let borrower = RuntimeEngine(source: .local, engineID: "shared-cache-specialization.\(label).borrower")
        try await borrower.connect()
        await borrower.setSharedCacheOwners(RuntimeSharedCacheOwners(partition: partition, macOS: owner, macCatalyst: nil))
        return Engines(borrower: borrower, owner: owner)
    }

    private final class BatchRecorder: @unchecked Sendable {
        private let lock = NSLock()

        private var startedBatches: [RuntimeIndexingBatch] = []

        private var task: Task<Void, Never>?

        init(listeningTo manager: RuntimeBackgroundIndexingManager) async {
            let stream = await manager.events
            task = Task { [weak self] in
                for await event in stream {
                    guard case .batchStarted(let batch) = event, let self else { continue }
                    lock.lock()
                    startedBatches.append(batch)
                    lock.unlock()
                }
            }
        }

        var batches: [RuntimeIndexingBatch] {
            lock.lock()
            defer { lock.unlock() }
            return startedBatches
        }

        /// The batches started so far, once one of them matches `predicate`
        /// or `timeout` has passed: the events reach the recorder on a task
        /// of its own, after the manager sent them.
        func batches(waitingFor predicate: (RuntimeIndexingBatch) -> Bool, timeout: Duration = .seconds(5)) async -> [RuntimeIndexingBatch] {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            while !batches.contains(where: predicate), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return batches
        }

        func stop() {
            task?.cancel()
        }
    }

    /// A type of the test process's own executable; not generic, so the
    /// request itself fails, but only after the images it waits for.
    private static func ownObject() -> RuntimeObject {
        RuntimeObject(name: "SharedCacheSpecializationOwnType", displayName: "SharedCacheSpecializationOwnType", kind: .swift(.type(.struct)), imagePath: ownImagePath, children: [])
    }

    @Test("A specialization of an own type has the serving process index the borrowed images it loaded first, and only once")
    func ownTypeIndexesBorrowedImagesFirst() async throws {
        let engines = try await Self.makeEngines(label: "own-type")
        // Listing the image's objects borrowed it: the owner indexed it for the borrower.
        _ = try await engines.borrower.objects(in: Self.sharedCacheImagePath)
        #expect(await !engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath))
        let recorder = await BatchRecorder(listeningTo: engines.borrower.backgroundIndexingManager)

        _ = try? await engines.borrower.specializationRequest(for: Self.ownObject())

        #expect(await engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath), "the serving process did not index the borrowed image before specializing")
        let startedBatches = await recorder.batches(waitingFor: { $0.reason == .specializationCandidates })
        let candidateBatches = startedBatches.filter { $0.reason == .specializationCandidates }
        #expect(candidateBatches.count == 1)
        #expect(candidateBatches.first?.items.map(\.id) == [Self.sharedCacheImagePath])

        _ = try? await engines.borrower.specializationRequest(for: Self.ownObject())

        // Time for a second batch's start to reach the recorder, had one started.
        try await Task.sleep(for: .milliseconds(300))
        #expect(recorder.batches.filter { $0.reason == .specializationCandidates }.count == 1, "a second specialization indexed the borrowed image again")
        recorder.stop()
        await engines.stop()
    }

    @Test("A specialization of a borrowed image's type indexes nothing in the borrower's serving process")
    func borrowedTypeIndexesNothingHere() async throws {
        let engines = try await Self.makeEngines(label: "borrowed-type")
        let objects = try await engines.borrower.objects(in: Self.sharedCacheImagePath)
        let borrowedObject = try #require(objects.first)
        let recorder = await BatchRecorder(listeningTo: engines.borrower.backgroundIndexingManager)

        _ = try? await engines.borrower.specializationRequest(for: borrowedObject)

        #expect(await !engines.borrower._isImageIndexed(path: Self.sharedCacheImagePath))
        try await Task.sleep(for: .milliseconds(300))
        #expect(!recorder.batches.contains { $0.reason == .specializationCandidates })
        recorder.stop()
        await engines.stop()
    }

    @Test("A specialization the owner registers for a borrowed image is announced on the borrower, one for an image of its own is not")
    func ownersSpecializationReachesTheBorrower() async throws {
        let engines = try await Self.makeEngines(label: "announce")
        var borrowerChanges: [RuntimeDataChange] = []
        let lock = NSLock()
        let subscription = engines.borrower.dataChangePublisher.sink { change in
            lock.withLock { borrowerChanges.append(change) }
        }
        defer { subscription.cancel() }
        let borrowedParent = RuntimeObject(name: "Borrowed", displayName: "Borrowed", kind: .swift(.type(.struct)), imagePath: Self.sharedCacheImagePath, children: [])
        let ownersOwnParent = RuntimeObject(name: "OwnersOwn", displayName: "OwnersOwn", kind: .swift(.type(.struct)), imagePath: Self.ownImagePath, children: [])

        engines.owner.dataChangeSubject.send(.specializationAdded(parent: ownersOwnParent, child: ownersOwnParent))
        engines.owner.dataChangeSubject.send(.specializationAdded(parent: borrowedParent, child: borrowedParent))

        let changes = lock.withLock { borrowerChanges }
        #expect(changes == [.specializationAdded(parent: borrowedParent, child: borrowedParent)])
        await engines.stop()
    }
}

#endif
