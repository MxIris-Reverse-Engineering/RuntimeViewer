import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// A document on an engine that borrows shared cache images holds the background work of the
/// engine it borrows from, as a borrower: the owner's work exists for it and serves it — its
/// indexing, its corpora — but the owner's own indexing starts only with a document on the owner.
/// Each image goes to the work that keeps its data, and the engine's owners changing puts a new
/// session in place.
@Suite("Borrowing an owner's background work", .serialized)
@MainActor
struct SharedCacheBorrowingTests {
    @Test("a document on a borrowing engine holds its owner's work, which starts none of the owner's own indexing")
    func borrowingStartsNothingOfTheOwners() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "starts")
        let borrowerEnvironment = Self.environment(on: fixture.borrowerEngine)
        borrowerEnvironment.startBackgroundWork()

        let session = borrowerEnvironment.documentState.runtimeEngineSession
        let ownerWork = try #require(borrowerEnvironment.backgroundWorkRegistry.backgroundWork(on: fixture.ownerEngine), "borrowing brought no work into being on the owner")
        #expect(session.borrowedBackgroundWorks.count == 1)
        #expect(session.borrowedBackgroundWorks.first === ownerWork)
        #expect(!ownerWork.indexingCoordinator.hasStarted, "a borrower started the owner's own indexing")
        #expect(try borrowerEnvironment.documentState.joinedIndexingCoordinator().hasStarted)

        let ownerEnvironment = Self.environment(on: fixture.ownerEngine)
        ownerEnvironment.startBackgroundWork()

        #expect(ownerEnvironment.documentState.runtimeEngineSession.backgroundWork === ownerWork, "the owner's document got other work than its borrower holds")
        #expect(ownerWork.indexingCoordinator.hasStarted, "the first document on the owner did not start its indexing")
        Self.close(borrowerEnvironment, ownerEnvironment)
        await fixture.stop()
    }

    @Test("the owner's work stays while a borrower or a member holds it, and closes with the last of them", arguments: [true, false])
    func ownersWorkClosesWithItsLastHolder(borrowerLeavesFirst: Bool) async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "closes.\(borrowerLeavesFirst)")
        let borrowerEnvironment = Self.environment(on: fixture.borrowerEngine)
        let ownerEnvironment = Self.environment(on: fixture.ownerEngine)
        borrowerEnvironment.startBackgroundWork()
        ownerEnvironment.startBackgroundWork()
        let registry = borrowerEnvironment.backgroundWorkRegistry
        let (firstToLeave, lastToLeave) = borrowerLeavesFirst ? (borrowerEnvironment, ownerEnvironment) : (ownerEnvironment, borrowerEnvironment)

        firstToLeave.make { firstToLeave.documentState.documentWillClose() }

        #expect(registry.backgroundWork(on: fixture.ownerEngine) != nil, "the owner's work closed while a document still held it")
        lastToLeave.make { lastToLeave.documentState.documentWillClose() }
        #expect(registry.backgroundWork(on: fixture.ownerEngine) == nil, "the owner's work outlived every document holding it")
        await fixture.stop()
    }

    @Test("a borrowed image goes to the owner's work, the sidebar's on-screen image included, and the engine's own images to its own")
    func imagesGoToTheWorkThatKeepsThem() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "routes")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let documentState = environment.documentState
        let session = documentState.runtimeEngineSession
        let ownWork = try #require(session.backgroundWork)
        let ownerWork = try #require(session.borrowedBackgroundWorks.first)

        #expect(session.backgroundWork(forImageAt: SharedCacheBorrowingFixture.borrowedImagePath) === ownerWork)
        #expect(session.backgroundWork(forImageAt: SharedCacheBorrowingFixture.ownImagePath) === ownWork)

        let imageTree = Fixtures.imageTree(rootName: RuntimeSharedCachePartition.imageRootNodeName, imagePaths: [SharedCacheBorrowingFixture.borrowedImagePath])
        let borrowedImageNode = try #require(imageTree.leaf(forImagePath: SharedCacheBorrowingFixture.borrowedImagePath))
        environment.make { documentState.selectionRouter.trigger(.switchImage(borrowedImageNode)) }

        let document = ObjectIdentifier(documentState)
        #expect(ownerWork.corpusCoordinator.onScreenImagePath(ofDocument: document) == SharedCacheBorrowingFixture.borrowedImagePath)
        #expect(ownWork.corpusCoordinator.onScreenImagePath(ofDocument: document) == nil)
        Self.close(environment)
        await fixture.stop()
    }

    @Test("the engine losing its owners puts a session without them in place, and a document that borrowed starts over", arguments: [false, true])
    func losingTheOwnersStartsOver(hasSomethingOpen: Bool) async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "loses.\(hasSomethingOpen)")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let documentState = environment.documentState
        if hasSomethingOpen {
            let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [SharedCacheBorrowingFixture.ownImagePath])
            let ownImageNode = try #require(imageTree.leaf(forImagePath: SharedCacheBorrowingFixture.ownImagePath))
            environment.make { documentState.selectionRouter.trigger(.switchImage(ownImageNode)) }
        }
        var resetEngines: [RuntimeEngine] = []
        var startOverEngines: [RuntimeEngine] = []
        let resetSubscription = documentState.runtimeEngineDidReset.emitOnNext { resetEngines.append($0) }
        let startOverSubscription = documentState.startOverRequested.emitOnNext { startOverEngines.append($0) }
        defer {
            resetSubscription.dispose()
            startOverSubscription.dispose()
        }

        await fixture.borrowerEngine.setSharedCacheOwners(nil)

        let session = try await nextValue(from: documentState.$runtimeEngineSession.asObservable()) { $0.borrowedBackgroundWorks.isEmpty }
        #expect(session.backgroundWork != nil, "the session put in place lets go of the engine's own work")
        #expect(session.backgroundWork === environment.backgroundWorkRegistry.backgroundWork(on: fixture.borrowerEngine), "the session put in place holds work from another registry")
        #expect(environment.backgroundWorkRegistry.backgroundWork(on: fixture.ownerEngine) == nil, "the owner's work outlived its only borrower")
        if hasSomethingOpen {
            #expect(startOverEngines.count == 1 && startOverEngines.first === fixture.borrowerEngine)
            #expect(resetEngines.isEmpty)
        } else {
            #expect(resetEngines.count == 1 && resetEngines.first === fixture.borrowerEngine)
            #expect(startOverEngines.isEmpty)
        }
        Self.close(environment)
        await fixture.stop()
    }

    @Test("a document that borrowed nothing moves to the owners the engine is given, without starting over")
    func gainingOwnersMovesWithoutStartingOver() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "gains", isBorrowing: false)
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.startBackgroundWork()
        let documentState = environment.documentState
        #expect(documentState.runtimeEngineSession.borrowedBackgroundWorks.isEmpty)
        var resetEngines: [RuntimeEngine] = []
        let resetSubscription = documentState.runtimeEngineDidReset.emitOnNext { resetEngines.append($0) }
        defer { resetSubscription.dispose() }

        await fixture.borrowerEngine.setSharedCacheOwners(fixture.owners)

        let session = try await nextValue(from: documentState.$runtimeEngineSession.asObservable()) { !$0.borrowedBackgroundWorks.isEmpty }
        #expect(session.borrowedBackgroundWorks.first === environment.backgroundWorkRegistry.backgroundWork(on: fixture.ownerEngine))
        #expect(resetEngines.isEmpty, "a document that showed nothing an owner gave it started over")
        Self.close(environment)
        await fixture.stop()
    }

    @Test("an Always Index row naming a borrowed image is indexed by the owner, for the borrower")
    func alwaysIndexRowGoesToTheOwner() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "alwaysIndex")
        let environment = Self.environment(on: fixture.borrowerEngine)
        let identifier = (SharedCacheBorrowingFixture.borrowedImagePath as NSString).lastPathComponent
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = [Settings.Indexing.AlwaysIndexEntry(identifier: identifier)]
        environment.startBackgroundWork()
        let ownerWork = try #require(environment.documentState.runtimeEngineSession.borrowedBackgroundWorks.first)

        let ownerHistory = try await nextValue(from: ownerWork.indexingCoordinator.historyObservable, timeout: 60) { history in
            history.contains { Self.isBorrowedAlwaysIndexBatch($0, identifier: identifier) }
        }

        let ownerBatch = try #require(ownerHistory.first { Self.isBorrowedAlwaysIndexBatch($0, identifier: identifier) })
        #expect(ownerBatch.items.map(\.id) == [SharedCacheBorrowingFixture.borrowedImagePath])
        let borrowerCoordinator = try environment.documentState.joinedIndexingCoordinator()
        let borrowerBatches = try await nextValue(from: borrowerCoordinator.historyObservable)
        #expect(!borrowerBatches.contains { $0.rootImagePath == SharedCacheBorrowingFixture.borrowedImagePath }, "the borrower indexed the image it handed over")
        Self.close(environment)
        await fixture.stop()
    }

    @Test("the Find navigator asks the owner's corpus coordinator for a borrowed image, which the engine's own leaves alone")
    func findAsksTheOwnerForABorrowedCorpus() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "corpus")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.settings.search.isCorpusEnabled = true
        environment.startBackgroundWork()
        let documentState = environment.documentState
        let ownCoordinator = try documentState.joinedCorpusCoordinator()
        let ownerCoordinator = try #require(documentState.runtimeEngineSession.borrowedBackgroundWorks.first).corpusCoordinator

        ownCoordinator.requestBuild(of: SharedCacheBorrowingFixture.borrowedImagePath)
        #expect(ownCoordinator.buildState(forImagePath: SharedCacheBorrowingFixture.borrowedImagePath) == nil, "the engine's own coordinator built a borrowed image's corpus")

        let findSession = environment.make { documentState.findSession }
        findSession.update { $0.scope = .images([SharedCacheBorrowingFixture.borrowedImagePath]) }

        #expect(ownerCoordinator.buildState(forImagePath: SharedCacheBorrowingFixture.borrowedImagePath) != nil, "the Find navigator did not ask the owner for the image in scope")
        #expect(ownCoordinator.buildState(forImagePath: SharedCacheBorrowingFixture.borrowedImagePath) == nil)
        Self.close(environment)
        await fixture.stop()
    }

    @Test("the corpus states the Find navigator reads take an owner's for the images it keeps for the engine, and only those")
    func mergedCorpusStatesNarrowTheOwners() async throws {
        let fixture = try await SharedCacheBorrowingFixture.make(label: "states")
        let environment = Self.environment(on: fixture.borrowerEngine)
        environment.settings.search.isCorpusEnabled = true
        environment.startBackgroundWork()
        let session = environment.documentState.runtimeEngineSession
        let ownerCoordinator = try #require(session.borrowedBackgroundWorks.first).corpusCoordinator
        // The owner's own process also has Foundation, which the borrower keeps itself.
        ownerCoordinator.requestBuild(of: SharedCacheBorrowingFixture.borrowedImagePath)
        ownerCoordinator.requestBuild(of: SharedCacheBorrowingFixture.ownImagePath)
        let corpusCoordinators = try #require(FindCorpusCoordinators(session: session))

        let states = try await nextValue(from: corpusCoordinators.buildStatesByImagePath) { $0[SharedCacheBorrowingFixture.borrowedImagePath] != nil }

        #expect(states[SharedCacheBorrowingFixture.ownImagePath] == nil, "an image of the owner's own process reached the borrower's Find navigator")
        Self.close(environment)
        await fixture.stop()
    }

    // MARK: - Support

    /// A document on `engine` whose indexing is off, so a document starting does not set the
    /// engine's process indexing the test runner's dependencies.
    private static func environment(on engine: RuntimeEngine) -> ViewModelTestEnvironment {
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        return environment
    }

    private static func close(_ environments: ViewModelTestEnvironment...) {
        for environment in environments {
            environment.make { environment.documentState.documentWillClose() }
        }
    }

    private static func isBorrowedAlwaysIndexBatch(_ batch: RuntimeIndexingBatch, identifier: String) -> Bool {
        guard case .borrowed(_, let reason) = batch.reason else { return false }
        return reason == .alwaysIndex(identifier: identifier)
    }
}
