import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerUI
import Testing
@testable import RuntimeViewerApplication
@testable import RuntimeViewerSettings

/// The Report navigator page against a private engine: indexing batches and corpus builds under
/// their own kind of work, rows that update in place, the actions the page forwards, the activity
/// mark on its tab, and the filter bar.
@Suite("ReportViewModel", .serialized)
@MainActor
struct ReportViewModelTests {
    /// Small, never indexed by a fresh engine, and quick to index for real.
    private static let smallImage = "/usr/lib/libSystem.B.dylib"

    /// The page's inputs as the test drives them, and its outputs.
    @MainActor
    private final class Page {
        /// Held here because the ViewModel keeps its router `unowned`.
        let router = MockRouter<SidebarRootRoute>()
        let cancelRelay = PublishRelay<ReportNode>()
        let cancelAllRelay = PublishRelay<Void>()
        let clearHistoryRelay = PublishRelay<Void>()
        let viewModel: ReportViewModel<SidebarRootRoute>
        let output: ReportViewModel<SidebarRootRoute>.Output

        init(documentState: DocumentState, filterString: Driver<String> = .just(""), showsOnlyInProgress: Driver<Bool> = .just(false)) {
            viewModel = ReportViewModel(documentState: documentState, router: router)
            output = viewModel.transform(ReportViewModel<SidebarRootRoute>.Input(
                appeared: .empty(),
                cancel: cancelRelay.asSignal(),
                cancelAll: cancelAllRelay.asSignal(),
                clearHistory: clearHistoryRelay.asSignal(),
                openSettings: .empty(),
                filterString: filterString,
                showsOnlyInProgress: showsOnlyInProgress
            ))
        }
    }

    // MARK: - The outline

    @Test("a finished indexing batch and a built corpus each show under their own kind of work")
    func finishedWorkUnderItsKind() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.tree", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let page = environment.make { Page(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }

        let batchID = await engine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual)

        let nodes = try await nextValue(from: page.output.nodes, timeout: 60) { nodes in
            Self.node(.indexingBatch(batchID), in: nodes)?.cellViewModel.isInProgress == false
                && Self.finishedCorpusRow(titled: "libobjc.A.dylib", in: nodes) != nil
        }

        #expect(nodes.map(\.identifier) == [.category(.backgroundIndexing), .category(.searchableInterfaces)])
        let batchRow = try #require(nodes.first?.children.first { $0.identifier == .indexingBatch(batchID) })
        #expect(batchRow.cellViewModel.appearance.title == "Manual Indexing")
        #expect(batchRow.cellViewModel.appearance.detail == "1 image")
        #expect(batchRow.children.map(\.cellViewModel.appearance.title) == ["libSystem.B.dylib"])
        let corpusRow = try #require(Self.finishedCorpusRow(titled: "libobjc.A.dylib", in: nodes))
        #expect(nodes.last?.children.contains { $0.identifier == corpusRow.identifier } == true)
        await engine.stop()
    }

    @Test("a feature turned off in Settings shows a single row saying so, which goes when it is turned back on")
    func turnedOffFeatureRow() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.turnedOff")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = false
        let page = environment.make { Page(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }

        let turnedOff = try await nextValue(from: page.output.nodes) { !$0.isEmpty }
        #expect(turnedOff.map { $0.children.map(\.identifier) } == [[.turnedOff(.backgroundIndexing)], [.turnedOff(.searchableInterfaces)]])

        environment.settings.search.isCorpusEnabled = true

        let turnedOn = try await nextValue(from: page.output.nodes) { $0.count == 1 }
        #expect(turnedOn.map(\.identifier) == [.category(.backgroundIndexing)])
        await engine.stop()
    }

    @Test("a corpus build's progress updates its row in place, leaving the outline as it was")
    func progressUpdatesRowInPlace() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.progress", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let page = environment.make { Page(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let buildIdentifier = ReportNodeIdentifier.corpusBuild(imagePath: TestImages.foundation)

        // The store builds one image at a time, so while Foundation prints — for tens of seconds —
        // libobjc's row stays as it is, waiting or done, and only Foundation's progress moves.
        let nodes = try await nextValue(from: page.output.nodes, timeout: 60) { Self.node(buildIdentifier, in: $0)?.cellViewModel.appearance.status == .running }
        let row = try #require(Self.node(buildIdentifier, in: nodes))
        let detail = row.cellViewModel.appearance.detail
        _ = try await nextValue(from: row.cellViewModel.$appearance.asDriver(), timeout: 60) { $0.detail != detail }

        let laterNodes = try await nextValue(from: page.output.nodes)
        #expect(Self.node(buildIdentifier, in: laterNodes)?.cellViewModel === row.cellViewModel)
        // `==` on nodes is identity only; whether the outline reloads is `isContentEqual(to:)`.
        #expect(laterNodes.elementsEqual(nodes) { $0.isContentEqual(to: $1) }, "the outline would reload for a change only the row's own cell shows")
        await engine.stop()
    }

    // MARK: - Actions

    @Test("cancelling a corpus build from its row moves it to the finished builds as cancelled")
    func cancelFromRow() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.cancel", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let page = environment.make { Page(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let buildIdentifier = ReportNodeIdentifier.corpusBuild(imagePath: TestImages.foundation)

        let nodes = try await nextValue(from: page.output.nodes, timeout: 60) { Self.node(buildIdentifier, in: $0)?.cellViewModel.isCancellable == true }
        page.cancelRelay.accept(try #require(Self.node(buildIdentifier, in: nodes)))

        let afterCancel = try await nextValue(from: page.output.nodes, timeout: 30) { nodes in
            Self.node(buildIdentifier, in: nodes) == nil && Self.finishedCorpusRow(titled: "Foundation", in: nodes) != nil
        }
        let cancelledRow = try #require(Self.finishedCorpusRow(titled: "Foundation", in: afterCancel))
        #expect(cancelledRow.cellViewModel.appearance.detail.hasPrefix("Cancelled"))
        #expect(!cancelledRow.cellViewModel.isInProgress)
        await engine.stop()
    }

    @Test("Clear History empties the finished work of both kinds")
    func clearHistoryEmptiesBothKinds() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.clearHistory", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Both on, so neither kind of work shows a row saying it is turned off.
        environment.settings.indexing.isEnabled = true
        environment.settings.search.isCorpusEnabled = true
        let page = environment.make { Page(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }

        let batchID = await engine.backgroundIndexingManager.startBatch(rootImagePath: Self.smallImage, depth: 0, maxConcurrency: 1, reason: .manual)
        // What the batch indexes gets its corpus built as well; wait for all of it, or a build
        // would land after the history is cleared.
        _ = try await nextValue(from: page.output.nodes, timeout: 120) { nodes in
            Self.node(.indexingBatch(batchID), in: nodes)?.cellViewModel.isInProgress == false
                && Self.finishedCorpusRow(titled: "libSystem.B.dylib", in: nodes) != nil
                && !Self.everyNode(in: nodes).contains { $0.cellViewModel.isInProgress }
        }

        page.clearHistoryRelay.accept(())
        try await settleMainQueue()

        let remaining = try await nextValue(from: page.output.nodes)
        #expect(remaining.isEmpty, "left after Clear History: \(Self.everyNode(in: remaining).map { "\($0.identifier) \($0.cellViewModel.appearance.title) \($0.cellViewModel.appearance.detail)" })")
        await engine.stop()
    }

    @Test("the Report navigator's tab is marked while work is in progress and unmarked once Cancel All ends it")
    func activityFollowsWorkInProgress() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.activity", loading: [TestImages.libobjc, TestImages.foundation])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.settings.search.isCorpusEnabled = true
        let page = environment.make { Page(documentState: environment.documentState) }
        defer { withExtendedLifetime(page) {} }
        let activity = environment.documentState.reportActivity

        // Foundation takes tens of seconds to print, so the mark is up long enough to see.
        _ = try await nextValue(from: activity, timeout: 60) { $0 }
        page.cancelAllRelay.accept(())

        #expect(try await nextValue(from: activity, timeout: 30) { !$0 } == false)
        await engine.stop()
    }

    // MARK: - The filter bar

    @Test("the outline shows its rows before the filter bar is touched")
    func outlineShowsBeforeFilterBarIsTouched() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "ReportViewModelTests.untouchedFilterBar")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        // Both turned off, so the outline has its rows at once, with nothing to index or build.
        environment.settings.indexing.isEnabled = false
        environment.settings.search.isCorpusEnabled = false
        // The page's own filter field, read the way the page reads it: its `rx.stringValue` reports
        // only what is typed into it, so an untouched field says nothing at all — nor does a clock
        // toggle nobody has clicked.
        let filterSearchField = FilterSearchField()
        let page = environment.make {
            Page(
                documentState: environment.documentState,
                filterString: filterSearchField.rx.stringValue.asDriver(onErrorJustReturn: ""),
                showsOnlyInProgress: .never()
            )
        }
        defer { withExtendedLifetime(page) {} }

        let nodes = try await nextValue(from: page.output.nodes) { !$0.isEmpty }

        #expect(nodes.map(\.identifier) == [.category(.backgroundIndexing), .category(.searchableInterfaces)])
        await engine.stop()
    }

    @Test("the filter keeps the rows whose name matches, under the kind of work they belong to")
    func filterKeepsMatchesUnderTheirKind() {
        let foundationRow = Self.row(.finishedCorpusBuild(UUID()), title: "Foundation")
        let libobjcRow = Self.row(.finishedCorpusBuild(UUID()), title: "libobjc.A.dylib")
        let corpusCategory = Self.row(.category(.searchableInterfaces), title: "Searchable Interfaces", children: [foundationRow, libobjcRow])
        let batchRow = Self.row(.indexingBatch(RuntimeIndexingBatchID()), title: "Manual Indexing")
        let indexingCategory = Self.row(.category(.backgroundIndexing), title: "Background Indexing", children: [batchRow])

        let filtered = ReportOutline.filtered([indexingCategory, corpusCategory], by: "found", showsOnlyInProgress: false)

        #expect(filtered.map(\.identifier) == [corpusCategory.identifier])
        #expect(filtered.first?.children.map(\.identifier) == [foundationRow.identifier])
    }

    @Test("the clock keeps only the work in progress, queued work included")
    func clockKeepsWorkInProgress() {
        let buildingRow = Self.row(.corpusBuild(imagePath: "/A"), title: "A", status: .running, isInProgress: true)
        let queuedRow = Self.row(.corpusBuild(imagePath: "/B"), title: "B", isInProgress: true)
        let finishedRow = Self.row(.finishedCorpusBuild(UUID()), title: "C")
        let corpusCategory = Self.row(.category(.searchableInterfaces), title: "Searchable Interfaces", children: [buildingRow, queuedRow, finishedRow])
        let finishedBatchRow = Self.row(.indexingBatch(RuntimeIndexingBatchID()), title: "Manual Indexing")
        let indexingCategory = Self.row(.category(.backgroundIndexing), title: "Background Indexing", children: [finishedBatchRow])

        let filtered = ReportOutline.filtered([indexingCategory, corpusCategory], by: "", showsOnlyInProgress: true)

        #expect(filtered.map(\.identifier) == [corpusCategory.identifier])
        #expect(filtered.first?.children.map(\.identifier) == [buildingRow.identifier, queuedRow.identifier])
    }

    /// An Always Index batch of one image shows no row for the image — the batch's row stands for
    /// it — so the image's own failure had nowhere to show, and the row said only "1 of 1 images
    /// failed to index". The toolbar popover it replaced listed the image as `path — message`
    /// (PR121.56).
    @Test("a single-image Always Index batch that failed says why on its own row")
    func flattenedAlwaysIndexFailureShowsItsReason() {
        let imagePath = "/usr/lib/libMissing.dylib"
        let batch = RuntimeIndexingBatch(
            id: RuntimeIndexingBatchID(),
            rootImagePath: imagePath,
            depth: 0,
            reason: .alwaysIndex(identifier: "libMissing.dylib"),
            items: [RuntimeIndexingTaskItem(id: imagePath, resolvedPath: imagePath, state: .failed(message: "image not found"), hasPriorityBoost: false)],
            isCancelled: false,
            isFinished: true
        )
        let cellViewModel = ReportCellViewModel(identifier: .indexingBatch(batch.id))

        ReportOutline.configure(cellViewModel, for: batch)

        #expect(!ReportOutline.showsItems(of: batch))
        #expect(cellViewModel.appearance.status == .failed(message: "image not found"))
        #expect(cellViewModel.appearance.detail == "Failed")
        #expect(cellViewModel.appearance.toolTip == "\(imagePath)\nimage not found")
    }

    // MARK: - Helpers

    private static func row(
        _ identifier: ReportNodeIdentifier,
        title: String,
        status: ReportRowStatus = .none,
        isInProgress: Bool = false,
        children: [ReportNode] = []
    ) -> ReportNode {
        let cellViewModel = ReportCellViewModel(identifier: identifier)
        cellViewModel.update(icon: nil, title: title, status: status, isInProgress: isInProgress)
        return ReportNode(identifier: identifier, cellViewModel: cellViewModel, children: children)
    }

    private static func everyNode(in nodes: [ReportNode]) -> [ReportNode] {
        nodes.flatMap { [$0] + everyNode(in: $0.children) }
    }

    private static func node(_ identifier: ReportNodeIdentifier, in nodes: [ReportNode]) -> ReportNode? {
        everyNode(in: nodes).first { $0.identifier == identifier }
    }

    private static func finishedCorpusRow(titled title: String, in nodes: [ReportNode]) -> ReportNode? {
        everyNode(in: nodes).first { node in
            guard case .finishedCorpusBuild = node.identifier else { return false }
            return node.cellViewModel.appearance.title == title
        }
    }
}
