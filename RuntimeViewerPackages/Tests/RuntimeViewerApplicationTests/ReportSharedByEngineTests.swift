#if canImport(Network)

import Foundation
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerCore
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The Report navigator is the engine's: the windows on one engine show the same Report, and only
/// windows on different engines show different ones. Every window used to keep a Report of its
/// own — an indexing history begun when it opened, corpus builds it alone could follow and cancel
/// — so a second window on an engine showed a Report of its own, Clear History and Cancel reached
/// the one window they were made in, and a window moved to another engine kept the history of the
/// one it left. `Documentations/Evolutions/0055-engine-scoped-background-work.md`.
@Suite("Report shared by the windows on an engine", .serialized)
@MainActor
struct ReportSharedByEngineTests {
    /// Small, never indexed by a fresh engine, and quick to index for real.
    private static let smallImage = "/usr/lib/libSystem.B.dylib"

    /// An image only the scripted engine lists; nothing loads it in this process.
    private static let scriptedImagePath = "/Scripted/libShared.dylib"

    // MARK: - A window opened on the engine

    @Test("a window opened on an engine shows the indexing history the window already on it shows")
    func laterWindowShowsTheEnginesIndexingHistory() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.indexingHistory")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableIndexingOnly(in: firstEnvironment)
        let firstPage = firstEnvironment.make { ReportPage(documentState: firstEnvironment.documentState) }
        defer { withExtendedLifetime(firstPage) {} }
        let batchIdentifier = try #require(await engine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual))
        let firstRows = try await Self.settledRows(of: firstPage) { rows in
            rows.contains { $0.identifier == .indexingBatch(batchIdentifier) }
        }

        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableIndexingOnly(in: secondEnvironment)
        let secondPage = secondEnvironment.make { ReportPage(documentState: secondEnvironment.documentState) }
        defer { withExtendedLifetime(secondPage) {} }

        let secondRows = try await Self.rows(of: secondPage, within: 5) { $0 == firstRows }
        #expect(secondRows == firstRows, "the second window's Report:\n\(Self.describe(secondRows))\nthe first window's:\n\(Self.describe(firstRows))")
        await engine.stop()
    }

    @Test("a window opened on an engine shows the corpus builds the window already on it shows")
    func laterWindowShowsTheEnginesCorpusBuilds() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.corpusBuilds", loading: [TestImages.libobjc])
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableCorporaOnly(in: firstEnvironment)
        let firstPage = firstEnvironment.make { ReportPage(documentState: firstEnvironment.documentState) }
        defer { withExtendedLifetime(firstPage) {} }
        let firstRows = try await Self.settledRows(of: firstPage) { rows in
            rows.contains { Self.isFinishedCorpusBuild($0, titled: "libobjc.A.dylib") }
        }

        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableCorporaOnly(in: secondEnvironment)
        let secondPage = secondEnvironment.make { ReportPage(documentState: secondEnvironment.documentState) }
        defer { withExtendedLifetime(secondPage) {} }

        let secondRows = try await Self.rows(of: secondPage, within: 5) { $0 == firstRows }
        #expect(secondRows == firstRows, "the second window's Report:\n\(Self.describe(secondRows))\nthe first window's:\n\(Self.describe(firstRows))")
        await engine.stop()
    }

    // MARK: - What one window does

    @Test("Clear History in one window clears it in every window on the engine")
    func clearHistoryReachesEveryWindowOnTheEngine() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.clearHistory")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableIndexingOnly(in: firstEnvironment)
        Self.enableIndexingOnly(in: secondEnvironment)
        let firstPage = firstEnvironment.make { ReportPage(documentState: firstEnvironment.documentState) }
        let secondPage = secondEnvironment.make { ReportPage(documentState: secondEnvironment.documentState) }
        defer { withExtendedLifetime((firstPage, secondPage)) {} }
        let batchIdentifier = try #require(await engine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual))
        for page in [firstPage, secondPage] {
            _ = try await Self.settledRows(of: page) { rows in rows.contains { $0.identifier == .indexingBatch(batchIdentifier) } }
        }

        firstPage.clearHistoryRelay.accept(())

        let secondRows = try await Self.rows(of: secondPage, within: 3) { rows in
            !rows.contains { $0.identifier == .indexingBatch(batchIdentifier) }
        }
        #expect(!secondRows.contains { $0.identifier == .indexingBatch(batchIdentifier) }, "Clear History in the first window left the second one's history:\n\(Self.describe(secondRows))")
        await engine.stop()
    }

    @Test("cancelling a corpus build in one window ends it in every window on the engine")
    func cancelReachesEveryWindowOnTheEngine() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.cancel", loading: [TestImages.libobjc, TestImages.foundation])
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableCorporaOnly(in: firstEnvironment)
        Self.enableCorporaOnly(in: secondEnvironment)
        let firstPage = firstEnvironment.make { ReportPage(documentState: firstEnvironment.documentState) }
        let secondPage = secondEnvironment.make { ReportPage(documentState: secondEnvironment.documentState) }
        defer { withExtendedLifetime((firstPage, secondPage)) {} }
        let buildIdentifier = ReportNodeIdentifier.corpusBuild(imagePath: TestImages.foundation)
        // Foundation takes tens of seconds to print, so its build is under way in both windows.
        try await Self.poll(timeout: 60) {
            firstPage.node(buildIdentifier)?.cellViewModel.isCancellable == true && secondPage.node(buildIdentifier) != nil
        }

        firstPage.cancelRelay.accept(try #require(firstPage.node(buildIdentifier)))

        let secondRows = try await Self.rows(of: secondPage, within: 10) { rows in
            !rows.contains { $0.identifier == buildIdentifier } && rows.contains { Self.isFinishedCorpusBuild($0, titled: "Foundation") }
        }
        #expect(!secondRows.contains { $0.identifier == buildIdentifier }, "the build cancelled in the first window runs on in the second:\n\(Self.describe(secondRows))")
        let foundationRow = secondRows.first { Self.isFinishedCorpusBuild($0, titled: "Foundation") }
        #expect(foundationRow?.detail.hasPrefix("Cancelled") == true, "the second window shows Foundation's build as \(foundationRow.map(\.description) ?? "nothing")")
        await engine.stop()
    }

    // MARK: - A window moving to another engine

    @Test("a window moved to another engine shows that engine's Report, its history included")
    func windowMovedToAnotherEngineShowsThatEnginesReport() async throws {
        let firstEngine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.movedWindow.first")
        let secondEngine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.movedWindow.second")
        let firstEnvironment = ViewModelTestEnvironment(runtimeEngine: firstEngine)
        let secondEnvironment = ViewModelTestEnvironment(runtimeEngine: secondEngine)
        Self.enableIndexingOnly(in: firstEnvironment)
        Self.enableIndexingOnly(in: secondEnvironment)
        let firstPage = firstEnvironment.make { ReportPage(documentState: firstEnvironment.documentState) }
        let secondPage = secondEnvironment.make { ReportPage(documentState: secondEnvironment.documentState) }
        defer { withExtendedLifetime((firstPage, secondPage)) {} }
        let firstBatchIdentifier = try #require(await firstEngine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual))
        let secondBatchIdentifier = try #require(await secondEngine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual))
        let firstRows = try await Self.settledRows(of: firstPage) { rows in rows.contains { $0.identifier == .indexingBatch(firstBatchIdentifier) } }
        _ = try await Self.settledRows(of: secondPage) { rows in rows.contains { $0.identifier == .indexingBatch(secondBatchIdentifier) } }

        secondEnvironment.make { secondEnvironment.documentState.selectionRouter.trigger(.switchEngine(firstEngine)) }

        let secondRows = try await Self.rows(of: secondPage, within: 5) { $0 == firstRows }
        #expect(secondRows == firstRows, "the window moved to the first engine shows:\n\(Self.describe(secondRows))\nthe window already there shows:\n\(Self.describe(firstRows))")
        await firstEngine.stop()
        await secondEngine.stop()
    }

    @Test("the last window leaving an engine empties the engine's Report")
    func lastWindowLeavingEmptiesTheEnginesReport() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.lastWindow")
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "ReportSharedByEngineTests.lastWindow.other")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        Self.enableIndexingOnly(in: environment)
        let page = environment.make { ReportPage(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let batchIdentifier = try #require(await engine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual))
        _ = try await Self.settledRows(of: page) { rows in rows.contains { $0.identifier == .indexingBatch(batchIdentifier) } }

        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine)) }
        environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(engine)) }
        // On the other engine for a moment, the Report showed nothing of the engine either; what
        // it shows once back is what counts.
        try await Task.sleep(for: .milliseconds(500))

        #expect(!page.rows.contains { $0.identifier == .indexingBatch(batchIdentifier) }, "the engine's Report outlived the last window on it:\n\(Self.describe(page.rows))")
        await engine.stop()
        await otherEngine.stop()
    }

    enum LastWindowLeaving: String, CaseIterable, Sendable {
        /// `Document.close()`.
        case closes
        /// The toolbar's engine menu, to another engine.
        case switchesToAnotherEngine
    }

    @Test("the last window leaving an engine cancels the engine's running batches", arguments: LastWindowLeaving.allCases)
    func lastWindowLeavingCancelsTheEnginesBatches(leaving: LastWindowLeaving) async throws {
        let label = "ReportSharedByEngineTests.lastWindowBatches.\(leaving.rawValue)"
        let peer = try await ScriptedPeer.make(label: label)
        let otherEngine = try await TestRuntimeEngine.makeConnected(engineID: "\(label).other")
        // Every load waits for the test, so the batch is still running when the window leaves.
        let heldLoads = HeldRequests()
        peer.serve(.isImageIndexed) { false }
        peer.serve(.loadImageForBackgroundIndexing) { () async -> RuntimeEngineEmpty in
            await heldLoads.hold()
            return RuntimeEngineEmpty()
        }
        try await peer.connection.sendMessage(name: .imageList, request: [Self.scriptedImagePath])
        try await Self.poll { await peer.client.imageList == [Self.scriptedImagePath] }
        let environment = ViewModelTestEnvironment(runtimeEngine: peer.client)
        let row = (Self.scriptedImagePath as NSString).lastPathComponent
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = true
        environment.settings.indexing.custom.entries = [Settings.Indexing.AlwaysIndexEntry(identifier: row)]
        let coordinator = environment.make { environment.documentState.backgroundIndexingCoordinator }
        defer { withExtendedLifetime((environment, coordinator)) {} }
        environment.make { coordinator.documentDidOpen() }
        try await Self.poll(timeout: 30) { await heldLoads.arrivedCount >= 1 }
        let batch = try #require(await peer.client.backgroundIndexingManager.currentBatches().first { $0.reason == .alwaysIndex(identifier: row) })

        switch leaving {
        case .closes:
            environment.make { environment.documentState.documentWillClose() }
        case .switchesToAnotherEngine:
            environment.make { environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine)) }
        }

        // A request on its way cannot be called back, so a cancelled batch ends only when its load
        // returns.
        let isCancelled: () async -> Bool = {
            await peer.client.backgroundIndexingManager.currentBatches().contains { $0.id == batch.id && $0.isCancelled }
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while await !isCancelled(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await isCancelled(), "the last window on the engine \(leaving.rawValue) and its batch runs on")
        await heldLoads.release()
        await peer.stop()
        await otherEngine.stop()
    }

    // MARK: - Support

    /// Background indexing on with nothing of its own to dispatch, corpora off: the only batches
    /// are the test's.
    private static func enableIndexingOnly(in environment: ViewModelTestEnvironment) {
        environment.settings.indexing.isEnabled = true
        environment.settings.indexing.heuristic.isEnabled = false
        environment.settings.indexing.custom.isEnabled = false
        environment.settings.search.isCorpusEnabled = false
    }

    /// Corpora on, background indexing off.
    private static func enableCorporaOnly(in environment: ViewModelTestEnvironment) {
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = true
    }

    private static func isFinishedCorpusBuild(_ row: ReportRow, titled title: String) -> Bool {
        guard case .finishedCorpusBuild = row.identifier else { return false }
        return row.title == title
    }

    /// `page`'s rows once `condition` holds, or as they stand when `timeout` runs out, so a test
    /// can say what it saw instead.
    private static func rows(of page: ReportPage, within timeout: TimeInterval, satisfying condition: ([ReportRow]) -> Bool) async throws -> [ReportRow] {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(page.rows), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        return page.rows
    }

    /// `page`'s rows once `condition` holds and nothing on the page is in progress.
    private static func settledRows(of page: ReportPage, timeout: TimeInterval = 60, where condition: ([ReportRow]) -> Bool) async throws -> [ReportRow] {
        let rows = try await rows(of: page, within: timeout) { rows in
            condition(rows) && !rows.contains(where: \.isInProgress)
        }
        try #require(condition(rows) && !rows.contains(where: \.isInProgress), "the Report never settled:\n\(describe(rows))")
        return rows
    }

    /// Polls `condition` until it holds, for state no observable reports.
    private static func poll(timeout: TimeInterval = 10, _ condition: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            guard Date() < deadline else { throw AwaitTimeout(seconds: timeout) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    private static func describe(_ rows: [ReportRow]) -> String {
        rows.map(\.description).joined(separator: "\n")
    }

    /// Every row of the outline, depth first, as the page shows it.
    fileprivate static func rows(of nodes: [ReportNode]) -> [ReportRow] {
        nodes.flatMap { node in
            [ReportRow(node: node)] + rows(of: node.children)
        }
    }
}

/// One row of the Report navigator as a window shows it.
private struct ReportRow: Equatable, CustomStringConvertible {
    let identifier: ReportNodeIdentifier
    let title: String
    let detail: String
    let isInProgress: Bool

    init(node: ReportNode) {
        identifier = node.identifier
        title = node.cellViewModel.appearance.title
        detail = node.cellViewModel.appearance.detail
        isInProgress = node.cellViewModel.isInProgress
    }

    var description: String {
        "\(identifier) · \(title) · \(detail)\(isInProgress ? " · in progress" : "")"
    }
}

/// A window's Report navigator page, on screen, keeping the outline it last showed.
@MainActor
private final class ReportPage {
    /// Held here because the ViewModel keeps its router `unowned`.
    let router = MockRouter<SidebarRootRoute>()
    let cancelRelay = PublishRelay<ReportNode>()
    let clearHistoryRelay = PublishRelay<Void>()
    let viewModel: ReportViewModel<SidebarRootRoute>
    private(set) var nodes: [ReportNode] = []
    private let disposeBag = DisposeBag()

    init(documentState: DocumentState) {
        viewModel = ReportViewModel(documentState: documentState, router: router)
        let output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
            isVisible: .just(true),
            cancel: cancelRelay.asSignal(),
            cancelAll: .empty(),
            clearHistory: clearHistoryRelay.asSignal(),
            openSettings: .empty(),
            doubleClickedNode: .empty(),
            filterString: .just(""),
            showsOnlyInProgress: .just(false)
        ))
        output.nodes.driveOnNext { [weak self] nodes in
            guard let self else { return }
            self.nodes = nodes
        }
        .disposed(by: disposeBag)
    }

    var rows: [ReportRow] {
        ReportSharedByEngineTests.rows(of: nodes)
    }

    func node(_ identifier: ReportNodeIdentifier) -> ReportNode? {
        func find(in nodes: [ReportNode]) -> ReportNode? {
            for node in nodes {
                if node.identifier == identifier { return node }
                if let match = find(in: node.children) { return match }
            }
            return nil
        }
        return find(in: nodes)
    }
}

#endif
