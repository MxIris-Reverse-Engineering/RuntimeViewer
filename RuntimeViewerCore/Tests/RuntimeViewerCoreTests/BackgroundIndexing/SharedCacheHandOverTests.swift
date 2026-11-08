import Foundation
import Testing
@testable import RuntimeViewerCore

/// Background indexing on an engine that borrows shared cache images: the
/// borrowed images its walk reaches are handed to their owner's indexing, and
/// an owner indexes them — with what lies below them — once, whoever asked.
@Suite final class SharedCacheHandOverTests {
    /// Keepalives: a manager holds its engine `unowned`.
    private var aliveObjects: [AnyObject] = []

    @discardableResult
    private func keep<Object: AnyObject>(_ object: Object) -> Object {
        aliveObjects.append(object)
        return object
    }

    private struct Engines {
        let borrower: MockBackgroundIndexingEngine
        let borrowerManager: RuntimeBackgroundIndexingManager
        let owner: MockBackgroundIndexingEngine
        let ownerManager: RuntimeBackgroundIndexingManager
    }

    private func makeEngines() -> Engines {
        let owner = keep(MockBackgroundIndexingEngine())
        let ownerManager = keep(RuntimeBackgroundIndexingManager(engine: owner))
        let borrower = keep(MockBackgroundIndexingEngine(borrowerName: "Finder"))
        let borrowerManager = keep(RuntimeBackgroundIndexingManager(engine: borrower))
        return Engines(borrower: borrower, borrowerManager: borrowerManager, owner: owner, ownerManager: ownerManager)
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test("A walk hands the borrowed images it reaches to their owner and indexes only its own")
    func walkHandsBorrowedImagesToTheOwner() async throws {
        let engines = makeEngines()
        engines.borrower.program(path: "/App", .init(dependencies: [
            ("Foundation", "/System/Foundation"),
            ("Own", "/App/Frameworks/Own"),
        ]))
        engines.borrower.program(path: "/App/Frameworks/Own", .init())
        engines.borrower.program(path: "/System/Foundation", .init(dependencies: [("CoreFoundation", "/System/CoreFoundation")]))
        engines.borrower.program(path: "/System/CoreFoundation", .init())
        engines.borrower.borrow("/System/Foundation", from: engines.ownerManager)
        engines.borrower.borrow("/System/CoreFoundation", from: engines.ownerManager)
        engines.owner.program(path: "/System/Foundation", .init(dependencies: [("CoreFoundation", "/System/CoreFoundation")]))
        engines.owner.program(path: "/System/CoreFoundation", .init())
        let ownerEvents = await engines.ownerManager.events

        _ = await engines.borrowerManager.startBatch(rootImagePath: "/App", depth: 2, maxConcurrency: 1, reason: .manual)

        var ownerEventIterator = ownerEvents.makeAsyncIterator()
        guard case .batchStarted(let ownerBatch)? = await ownerEventIterator.next() else {
            Issue.record("the owner started no batch")
            return
        }
        #expect(ownerBatch.reason == .borrowed(borrowerName: "Finder", reason: .manual))
        #expect(Set(ownerBatch.items.map(\.id)) == ["/System/Foundation", "/System/CoreFoundation"])
        #expect(await waitUntil { Set(engines.owner.loadedOrder()) == ["/System/Foundation", "/System/CoreFoundation"] })
        #expect(await waitUntil { Set(engines.borrower.loadedOrder()) == ["/App", "/App/Frameworks/Own"] })
    }

    @Test("A borrowed image the serving process has not loaded is handed over, not failed")
    func unopenableBorrowedImageIsHandedOver() async throws {
        let engines = makeEngines()
        engines.borrower.program(path: "/App", .init(dependencies: [("Unloaded", "/System/Unloaded")]))
        engines.borrower.borrow("/System/Unloaded", from: engines.ownerManager)
        engines.owner.program(path: "/System/Unloaded", .init())

        _ = await engines.borrowerManager.startBatch(rootImagePath: "/App", depth: 1, maxConcurrency: 1, reason: .manual)

        #expect(await waitUntil { engines.owner.loadedOrder() == ["/System/Unloaded"] })
        #expect(await waitUntil { engines.borrower.loadedOrder() == ["/App"] })
    }

    @Test("A walk of nothing but borrowed images starts no batch of the borrower's own")
    func onlyBorrowedImagesStartNoOwnBatch() async throws {
        let engines = makeEngines()
        engines.borrower.program(path: "/System/AppKit", .init())
        engines.borrower.borrow("/System/AppKit", from: engines.ownerManager)
        engines.owner.program(path: "/System/AppKit", .init())

        let batchIdentifier = await engines.borrowerManager.startBatch(rootImagePath: "/System/AppKit", depth: 0, maxConcurrency: 1, reason: .alwaysIndex(identifier: "AppKit"))

        #expect(batchIdentifier == nil)
        #expect(await waitUntil { engines.owner.loadedOrder() == ["/System/AppKit"] })
    }

    @Test("An owner leaves an image another batch is indexing to that batch")
    func ownerSkipsImagesUnderWay() async throws {
        let engines = makeEngines()
        let roots = ["/System/A", "/System/B", "/System/C", "/System/D", "/System/E"]
        for root in roots {
            engines.owner.program(path: root, .init())
        }

        let firstBatch = await engines.ownerManager.startBatch(roots: roots.map { RuntimeIndexingBatchRoot(imagePath: $0, depth: 0) }, maxConcurrency: 1, reason: .manual)
        let secondBatch = await engines.ownerManager.startBatch(roots: [RuntimeIndexingBatchRoot(imagePath: "/System/E", depth: 0)], maxConcurrency: 1, reason: .manual)

        #expect(firstBatch != nil)
        #expect(secondBatch == nil)
        #expect(await waitUntil { engines.owner.loadedOrder().count == roots.count })
        #expect(engines.owner.loadedOrder().filter { $0 == "/System/E" }.count == 1)
    }

    @Test("An owner loads a shared cache root no process has loaded before it reads the root's dependencies")
    func ownerLoadsAnUnloadedRootFirst() async throws {
        let engines = makeEngines()
        engines.owner.program(path: "/System/Contacts", .init(dependencies: [("AddressBook", "/System/AddressBook")]))
        engines.owner.program(path: "/System/AddressBook", .init())
        engines.owner.ownSharedCacheImage("/System/Contacts")
        engines.owner.leaveUnloaded("/System/Contacts")

        _ = await engines.ownerManager.startBatch(rootImagePath: "/System/Contacts", depth: 1, maxConcurrency: 1, reason: .alwaysIndex(identifier: "Contacts"))

        #expect(await waitUntil { engines.owner.loadedOrder().contains("/System/AddressBook") })
    }

    @Test("A borrowed batch counts as the kind of batch it was borrowed for")
    func borrowedReasonFollowsItsReason() {
        let heuristic = RuntimeIndexingBatchReason.borrowed(borrowerName: "Finder", reason: .appLaunch)
        let custom = RuntimeIndexingBatchReason.borrowed(borrowerName: "Finder", reason: .alwaysIndex(identifier: "AppKit"))

        #expect(heuristic.isHeuristic)
        #expect(!heuristic.isCustom)
        #expect(heuristic.category == .heuristic)
        #expect(custom.isCustom)
        #expect(custom.category == .alwaysIndex)
    }
}
