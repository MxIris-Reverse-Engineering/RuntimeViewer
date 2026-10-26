import Foundation
@testable import RuntimeViewerCore
import Synchronization
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// Corpora read from derived data, on the app's side: the Always Index images
/// read as their rows are dispatched and before they are indexed, the reads
/// handled as finished builds and listed apart in the Report, and the panes
/// that meet an object whose image has no sections yet loading it.
@Suite("Corpora read from derived data", .serialized)
@MainActor
struct DerivedDataRestoreTests {
    /// The corpus of libobjc stored under the environment's transformer, and
    /// an engine on the same derived data that has indexed nothing.
    private static func makeReaderEngine(_ label: String, fixture: DerivedDataFixture, environmentTransformer: Transformer.Configuration) async throws -> RuntimeEngine {
        try await fixture.storeCorpus(of: TestImages.libobjc, transformer: environmentTransformer)
        let engine = try await fixture.makeEngine(label)
        #expect(try await !engine.isImageIndexed(path: TestImages.libobjc))
        return engine
    }

    private static func isLibobjcRead(_ restoredImages: [String: RuntimeInterfaceCorpusRestoredImage]) -> Bool {
        restoredImages[TestImages.libobjc] != nil
    }

    @Test("a restore reads the stored corpus without indexing, and it is handled as a finished build")
    func restoreReadsWithoutIndexing() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("restore", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }
        var builtImagePaths: [String] = []
        let corpusBuiltSubscription = coordinator.corpusBuilt.emitOnNext { builtImagePaths.append($0) }
        defer { corpusBuiltSubscription.dispose() }

        coordinator.restoreCorpora(of: [TestImages.libobjc])

        let restoredImages = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        #expect(restoredImages[TestImages.libobjc]?.summary.objectCount ?? 0 > 0)
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc]?.isBuilt == true)
        #expect(builtImagePaths == [TestImages.libobjc], "a search on screen widens to the image")
        #expect(coordinator.finishedBuilds.isEmpty, "a read is no build")
        #expect(coordinator.restoringImagePaths.isEmpty)
        #expect(try await !engine.isImageIndexed(path: TestImages.libobjc))

        var matches: [RuntimeInterfaceSearchMatch] = []
        _ = try await engine.searchInterfaces(RuntimeInterfaceSearchQuery(text: "NSObject", matchMode: .matchingWord, isCaseSensitive: true)) { matches += $0 }
        #expect(!matches.isEmpty, "searchable before it is indexed")
        await engine.stop()
    }

    @Test("an Always Index row's image is read as the row is dispatched, and its indexing prints nothing")
    func alwaysIndexDispatchReads() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("always-index", fixture: fixture, environmentTransformer: environment.settings.transformer)
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = [Settings.Indexing.AlwaysIndexEntry(identifier: "libobjc.A.dylib")]
        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(engine)) }
        environment.startBackgroundWork()
        let indexingCoordinator = try environment.documentState.joinedIndexingCoordinator()
        let corpusCoordinator = try environment.documentState.joinedCorpusCoordinator()
        defer { withExtendedLifetime((indexingCoordinator, corpusCoordinator)) {} }

        _ = try await nextValue(from: corpusCoordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        // The row's batch indexes the image; its corpus is there already.
        _ = try await nextValue(from: indexingCoordinator.historyObservable, timeout: 60) { history in
            history.contains { $0.rootImagePath == TestImages.libobjc && $0.isFinished }
        }
        try await waitUntil(timeout: 30) { !corpusCoordinator.hasWorkUnderWay }
        #expect(try await engine.isImageIndexed(path: TestImages.libobjc))
        #expect(corpusCoordinator.finishedBuilds.isEmpty, "the corpus was printed again: \(corpusCoordinator.finishedBuilds)")
        #expect(Self.isLibobjcRead(corpusCoordinator.restoredImagesByImagePath))
        await engine.stop()
    }

    @Test("an Always Index batch that starts has its waiting images read")
    func alwaysIndexBatchStartReads() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("batch-start", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }
        // Let the coordinator's subscription to the indexer's events come up.
        try await Task.sleep(for: .milliseconds(200))

        _ = await engine.backgroundIndexingManager.startBatch(
            rootImagePath: TestImages.libobjc,
            depth: 0,
            maxConcurrency: 1,
            reason: .alwaysIndex(identifier: "libobjc.A.dylib")
        )

        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        try await waitUntil(timeout: 30) { !coordinator.hasWorkUnderWay }
        #expect(coordinator.finishedBuilds.isEmpty)
        await engine.stop()
    }

    @Test("an image opened by hand reads its corpus instead of printing it, and is listed as read")
    func manualOpenReads() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("manual", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }

        try await engine.loadImage(at: TestImages.libobjc)

        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc]?.isBuilt == true)
        #expect(coordinator.finishedBuilds.isEmpty, "the corpus was printed again")
        await engine.stop()
    }

    @Test("Clear History empties the group, and a refresh does not bring it back")
    func clearHistoryEmptiesTheGroup() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("clear", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.restoreCorpora(of: [TestImages.libobjc])
        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        try await waitUntil(timeout: 30) { !coordinator.hasWorkUnderWay }

        coordinator.clearFinishedBuilds()
        #expect(coordinator.restoredImagesByImagePath.isEmpty)
        let fetchCount = coordinator.coverageFetchCount
        coordinator.refreshCoverage()
        try await waitUntil(timeout: 30) { coordinator.coverageFetchCount > fetchCount && !coordinator.hasWorkUnderWay }
        #expect(coordinator.restoredImagesByImagePath.isEmpty, "a cleared image came back with the next coverage")
        #expect(coordinator.finishedBuilds.isEmpty, "a read corpus was taken for a build made elsewhere")
        await engine.stop()
    }

    @Test("a transformer change drops the group and prints the image again")
    func transformerChangePrintsAgain() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("transformer", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }
        try await engine.loadImage(at: TestImages.libobjc)
        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)

        environment.settings.transformer.objc.cType.isEnabled.toggle()

        _ = try await nextValue(from: coordinator.$finishedBuilds.asDriver(), timeout: 60) { finishedBuilds in
            finishedBuilds.contains { finishedBuild in
                guard finishedBuild.imagePath == TestImages.libobjc, case .built = finishedBuild.outcome else { return false }
                return true
            }
        }
        #expect(coordinator.restoredImagesByImagePath.isEmpty)
        await engine.stop()
    }

    /// An image read but not indexed has nothing to print from: asking for
    /// its build again, all the switch going back on did, left it out of
    /// search (PR126.2).
    @Test("turning the corpus switch off and on reads again the images read before, unindexed as they are")
    func switchOffAndOnReadsAgain() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("switch", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.restoreCorpora(of: [TestImages.libobjc])
        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        try await waitUntil(timeout: 30) { !coordinator.hasWorkUnderWay }

        environment.settings.search.isCorpusEnabled = false
        try await waitUntil(timeout: 30) { coordinator.buildStatesByImagePath.isEmpty && coordinator.restoredImagesByImagePath.isEmpty }
        environment.settings.search.isCorpusEnabled = true

        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc]?.isBuilt == true)
        #expect(try await !engine.isImageIndexed(path: TestImages.libobjc))
        await engine.stop()
    }

    /// Derived data keeps one variant per image, so under the edited
    /// transformer there is nothing to read; back under the old one there is
    /// again (PR126.2).
    @Test("a transformer edit taken back reads again the images read before, unindexed as they are")
    func transformerEditTakenBackReadsAgain() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("transformer-back", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }
        coordinator.restoreCorpora(of: [TestImages.libobjc])
        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        try await waitUntil(timeout: 30) { !coordinator.hasWorkUnderWay }

        let editRebuild = Task { try await nextValue(from: coordinator.corporaRebuilt, timeout: 30) }
        environment.settings.transformer.objc.cType.isEnabled.toggle()
        try await editRebuild.value
        try await waitUntil(timeout: 30) { !coordinator.hasWorkUnderWay }
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc] == nil, "nothing is stored under the edited transformer")

        let takeBackRebuild = Task { try await nextValue(from: coordinator.corporaRebuilt, timeout: 30) }
        environment.settings.transformer.objc.cType.isEnabled.toggle()
        try await takeBackRebuild.value

        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc]?.isBuilt == true)
        await engine.stop()
    }

    /// The engine's store counts a read under way as a build waiting for the
    /// printer, which the Report listed among the queued corpora (PR126.4).
    @Test("a coverage taken while an image is read does not list the image as queued")
    func coverageWhileReadingListsNothingQueued() async throws {
        let fixture = try DerivedDataFixture()
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await Self.makeReaderEngine("coverage-while-reading", fixture: fixture, environmentTransformer: environment.settings.transformer)
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.restoreCorpora(of: [TestImages.libobjc])
        #expect(coordinator.restoringImagePaths == [TestImages.libobjc])
        coordinator.mergeCoverage(RuntimeInterfaceCorpusCoverage(statesByImagePath: [TestImages.libobjc: .pending], residentByteCount: 0, residentByteLimit: 0))

        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc] == nil, "listed among the queued corpora while it is read")
        _ = try await nextValue(from: coordinator.$restoredImagesByImagePath.asDriver(), timeout: 30, where: Self.isLibobjcRead)
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc]?.isBuilt == true)
        await engine.stop()
    }

    @Test("an engine whose process keeps no derived data reads nothing")
    func noDerivedData() async throws {
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataRestoreTests.none")
        let coordinator = environment.make { FindCorpusCoordinator(engine: engine) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.restoreCorpora(of: [TestImages.libobjc])
        try await waitUntil(timeout: 30) { !coordinator.hasWorkUnderWay }
        #expect(coordinator.restoredImagesByImagePath.isEmpty)
        #expect(coordinator.restoringImagePaths.isEmpty)
        #expect(coordinator.buildStatesByImagePath[TestImages.libobjc] == nil)
        await engine.stop()
    }

    #if canImport(Network)
    @Test("a peer that predates the restore command reads nothing and still builds")
    func peerWithoutRestore() async throws {
        let peer = try await ScriptedPeer.make(label: "DerivedDataRestoreTests.older")
        defer { Task { await peer.stop() } }
        let summary = RuntimeInterfaceCorpusBuildSummary(objectCount: 3, skippedCount: 0, byteCount: 300)
        peer.serve(.interfaceCorpusCoverage) { RuntimeInterfaceCorpusCoverage.empty }
        peer.serve(.indexedImagePaths) { [String]() }
        peer.serve(.setInterfaceCorpusResidentByteLimit) { RuntimeEngineEmpty() }
        peer.serve(.buildInterfaceCorpus) { RuntimeInterfaceCorpusBuildOutcome.built(summary) }
        let environment = ViewModelTestEnvironment()
        environment.settings.search.isCorpusEnabled = true
        let coordinator = environment.make { FindCorpusCoordinator(engine: peer.client) }
        defer { withExtendedLifetime(coordinator) {} }

        coordinator.restoreCorpora(of: [TestImages.libobjc])
        try await waitUntil(timeout: 30) { coordinator.restoringImagePaths.isEmpty }
        #expect(coordinator.restoredImagesByImagePath.isEmpty)
        #expect(!coordinator.isCorpusUnsupportedByEngine, "a peer without the restore command is no peer without corpora")

        coordinator.requestBuild(of: TestImages.libobjc)
        let states = try await nextValue(from: coordinator.$buildStatesByImagePath.asDriver(), timeout: 30) { $0[TestImages.libobjc]?.isBuilt == true }
        #expect(states[TestImages.libobjc] == .built(summary))
    }
    #endif

    // MARK: - Panes

    @Test("the content pane loads the image of a Swift object that has no sections, then shows its interface")
    func contentPaneLoadsTheImage() async throws {
        let overlayPath = "/usr/lib/swift/libswiftAccelerate.dylib"
        let writer = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataRestoreTests.content.writer", loading: [overlayPath])
        let swiftStruct = try #require(try await writer.objects(in: overlayPath).first { $0.kind == .swift(.type(.struct)) })
        await writer.stop()
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataRestoreTests.content")
        #expect(try await !engine.isImageIndexed(path: overlayPath))
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let viewModel = environment.make {
            ContentTextViewModel(runtimeObject: swiftStruct, documentState: environment.documentState, router: MockRouter<ContentRoute>())
        }
        defer { withExtendedLifetime(viewModel) {} }

        let rendered = try await nextValue(from: viewModel.$renderedInterface.asObservable(), timeout: 120) { $0 != nil }
        #expect(rendered?.attributedString.length ?? 0 > 0)
        #expect(try await engine.isImageIndexed(path: overlayPath))
        await engine.stop()
    }

    @Test("the Inspector's relationships are asked for again once the object's image is indexed")
    func inspectorRefetchesOnceIndexed() async throws {
        let nsString = try await TestRuntimeEngine.shared().runtimeObject(named: "NSString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataRestoreTests.inspector", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let viewModel = environment.make {
            InspectorRelationshipsViewModel(runtimeObject: nsString, documentState: environment.documentState, router: MockRouter<InspectorRuntimeObjectRoute>())
        }
        defer { withExtendedLifetime(viewModel) {} }
        let output = viewModel.transform(.init(selectRelationshipClicked: .empty()))
        _ = try await nextValue(from: output.state, timeout: 30) { state in
            if case .loaded(let rows) = state { return rows.isEmpty }
            return false
        }

        try await engine.loadImage(at: TestImages.foundation)

        let state = try await nextValue(from: output.state, timeout: 120) { state in
            if case .loaded(let rows) = state { return !rows.isEmpty }
            return false
        }
        guard case .loaded(let rows) = state else { return }
        #expect(rows.map(\.runtimeObject.name).contains("NSMutableString"))
        await engine.stop()
    }

    /// The tab said the image was not indexed and stayed so, the image built
    /// meanwhile, until the object was chosen again (PR126.17).
    @Test("the Inspector's references are asked for again once the object's image is indexed")
    func inspectorReferencesRefetchOnceIndexed() async throws {
        let mutableString = try await TestRuntimeEngine.shared().runtimeObject(named: "NSMutableString", kind: .objc(.type(.class)), in: TestImages.foundation)
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "DerivedDataRestoreTests.inspectorReferences", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let viewModel = environment.make {
            InspectorReferencesViewModel(runtimeObject: mutableString, documentState: environment.documentState, router: MockRouter<InspectorRuntimeObjectRoute>())
        }
        defer { withExtendedLifetime(viewModel) {} }
        let output = viewModel.transform(.init(rowClicked: .empty(), showInFindNavigatorClicked: .empty(), isVisible: .just(true)))
        _ = try await nextValue(from: output.typeReferences, timeout: 30) { state in
            if case .failed = state { return true }
            return false
        }

        try await engine.loadImage(at: TestImages.foundation)

        _ = try await nextValue(from: output.typeReferences, timeout: 120) { state in
            if case .loaded(let rows, _, _) = state { return !rows.isEmpty }
            return false
        }
        await engine.stop()
    }

    /// The pane does not ask again by itself: an interface that came back
    /// `nil` because background indexing finished the image a moment later
    /// left it blank (PR126.16).
    @Test("an interface that comes back nil from an image indexed by the time it is checked is asked for again")
    func contentInterfaceAskedForAgain() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsString = try await engine.runtimeObject(named: "NSString", kind: .objc(.type(.class)), in: TestImages.foundation)
        #expect(try await engine.isImageIndexed(path: TestImages.foundation))
        let askCount = Mutex(0)

        let interface = try await ContentTextViewModel.interface(of: nsString, fetchingWith: {
            let ask = askCount.withLock { count in
                count += 1
                return count
            }
            return ask == 1 ? nil : RuntimeObjectInterface(object: nsString, interfaceString: "@interface NSString : NSObject\n@end")
        }, runtimeEngine: { engine })

        #expect(interface != nil)
    }

    // MARK: - Report

    @Test("the Report lists the corpora read under a group of their own, ahead of the ended builds")
    func reportGroupsTheReads() throws {
        let builder = ReportTreeBuilder()
        let foundationPath = TestImages.foundation
        let summary = RuntimeInterfaceCorpusBuildSummary(objectCount: 10, skippedCount: 0, byteCount: 2_000_000)
        let category = try #require(builder.corpusCategory(
            states: [TestImages.libobjc: .built(summary), foundationPath: .built(summary)],
            followedImagePaths: [],
            finishedBuilds: [FindCorpusFinishedBuild(imagePath: "/usr/lib/libz.1.dylib", outcome: .built(summary), finishedAt: Date())],
            restoredImages: [
                foundationPath: RuntimeInterfaceCorpusRestoredImage(summary: summary, duration: 0.25),
                TestImages.libobjc: RuntimeInterfaceCorpusRestoredImage(summary: summary, duration: 0.05),
            ],
            isUnsupportedByEngine: false,
            isEnabled: true
        ))
        let group = try #require(category.children.first { $0.identifier == .restoredCorpora })
        #expect(category.children.firstIndex { $0.identifier == .restoredCorpora } == 0, "nothing queued, so the group comes first")
        #expect(category.children.last?.identifier != .restoredCorpora, "the ended builds follow it")
        #expect(group.cellViewModel.appearance.title == "Restored from Derived Data")
        #expect(group.cellViewModel.appearance.detail == "2 images")
        #expect(group.children.map(\.identifier) == [.restoredCorpus(imagePath: foundationPath), .restoredCorpus(imagePath: TestImages.libobjc)], "by image name")
        let foundationRow = try #require(group.children.first)
        #expect(foundationRow.cellViewModel.appearance.detail.hasSuffix("· 0.25 s"))
        #expect(!foundationRow.cellViewModel.isCancellable)
        #expect(!foundationRow.cellViewModel.isInProgress)

        let withoutReads = try #require(builder.corpusCategory(
            states: [:],
            followedImagePaths: [],
            finishedBuilds: [FindCorpusFinishedBuild(imagePath: "/usr/lib/libz.1.dylib", outcome: .built(summary), finishedAt: Date())],
            restoredImages: [:],
            isUnsupportedByEngine: false,
            isEnabled: true
        ))
        #expect(!withoutReads.children.contains { $0.identifier == .restoredCorpora })
    }
}
