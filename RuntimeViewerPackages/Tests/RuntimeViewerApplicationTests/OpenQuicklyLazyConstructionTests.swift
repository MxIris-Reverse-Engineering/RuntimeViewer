import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// Regression suite for Open Quickly's lazy row materialization.
///
/// History: before this change, `SidebarRuntimeObjectListViewModel.reloadData`
/// eagerly built a second full copy of the sidebar's cell view models
/// (`forOpenQuickly: true`) on the main thread — N cell constructions
/// (icons, attributed titles, child trees) per image load, ~250 ms at
/// N = 10k in a debug build, for a list most sessions never open. Now the
/// reload stores only the sorted value array; matching runs against pure
/// haystack strings computed off-main, and cell view models materialize
/// only for rows a query actually surfaces.
@Suite("OpenQuicklyLazyConstruction", .serialized)
@MainActor
struct OpenQuicklyLazyConstructionTests {
    private static let seededObjectCount = 2_000

    // MARK: - Haystack parity (the highlight-range contract)

    @Test("pure-value haystack is byte-identical to the cell view model's")
    func haystackParity() {
        let grandchild = makeRuntimeObject(displayName: "TestFramework.Parent.Child.Grandchild")
        let secondChild = makeRuntimeObject(displayName: "TestFramework.Parent.AChild")
        let firstChild = makeRuntimeObject(displayName: "TestFramework.Parent.Child", children: [grandchild])
        // Children intentionally out of display order: both sides must
        // sort by displayName before joining, or fuzzy highlight ranges
        // computed against the pure haystack would land on the wrong
        // characters of the materialized cell's haystack.
        let parent = makeRuntimeObject(
            displayName: "TestFramework.Parent",
            children: [firstChild, secondChild]
        )

        for runtimeObject in [parent, firstChild, grandchild, makeRuntimeObject(displayName: "TestFramework.Leaf")] {
            let cellViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: runtimeObject, forOpenQuickly: true)
            #expect(
                SidebarRuntimeObjectCellViewModel.haystack(for: runtimeObject) == cellViewModel.currentAndChildrenNames,
                "haystack diverged for \(runtimeObject.displayName)"
            )
        }
    }

    // MARK: - End-to-end lazy contract

    @Test("reload materializes zero rows; queries materialize only matches")
    func lazyMaterializationEndToEnd() async throws {
        // The seeded view model subscribes to the shared local engine's
        // data-change broadcasts; a concurrent suite firing a real
        // `.fullReload` (the interface-cache flush test) would reload the
        // fixture mid-assertion and rebuild the materialized-row cache.
        // Hold the cross-suite lock (see SharedLocalEngineTestLock.swift).
        try await withSharedLocalEngineLock {
            try await runLazyMaterializationEndToEnd()
        }
    }

    private func runLazyMaterializationEndToEnd() async throws {
        let localRuntimeEngine = RuntimeEngine.local

        var imageList: [String] = []
        let engineReady = try await pollUntil(timeout: .seconds(15)) {
            imageList = await localRuntimeEngine.imageList
            return !imageList.isEmpty
        }
        #expect(engineReady, "local engine never published an image list")
        let loadedImagePath = try #require(
            imageList.first { $0.hasSuffix("/Foundation") } ?? imageList.first
        )

        let rootImageNode = RuntimeImageNode.rootNode(for: [loadedImagePath], name: "Root")
        var imageNode = rootImageNode
        while let firstChild = imageNode.children.first {
            imageNode = firstChild
        }

        let documentState = DocumentState()
        let mockRouter = MockRouter<SidebarRuntimeObjectRoute>()
        let seededRuntimeObjects = makeFlatRuntimeObjects(count: Self.seededObjectCount)
        let viewModel = SeededOpenQuicklyListViewModel(
            seededRuntimeObjects: seededRuntimeObjects,
            imageNode: imageNode,
            documentState: documentState,
            router: mockRouter
        )
        let reloadFinished = try await pollUntil(timeout: .seconds(30)) {
            viewModel.loadState == .loaded
        }
        #expect(reloadFinished, "seeded reload never reached .loaded")

        // The headline assertion: a reload materializes NOTHING for Open
        // Quickly. The legacy path had already built all N rows here.
        #expect(viewModel.openQuicklyCellViewModelsByRowIndex.isEmpty)
        #expect(viewModel.filteredNodesForOpenQuickly.isEmpty)

        let searchStringRelay = PublishRelay<String>()
        let input = SidebarRuntimeObjectListViewModel.Input(
            runtimeObjectClickedForOpenQuickly: .never(),
            searchStringForOpenQuickly: searchStringRelay.asSignal(),
            addBookmark: .never()
        )
        _ = viewModel.transform(input)

        // The input stream drops its first element (the search field's
        // initial value in the real UI), so prime it before querying.
        searchStringRelay.accept("")

        let expectedNeedleMatchCount = Self.seededObjectCount / 100
        searchStringRelay.accept("Needle")
        let searchApplied = try await pollUntil(timeout: .seconds(10)) {
            viewModel.filteredNodesForOpenQuickly.count == expectedNeedleMatchCount
        }
        #expect(searchApplied, "search never produced \(expectedNeedleMatchCount) filtered rows")

        // Only the matched rows exist as cell view models, every one of
        // them carries a highlight, and the published array is exactly
        // the materialized set.
        #expect(viewModel.openQuicklyCellViewModelsByRowIndex.count == expectedNeedleMatchCount)
        #expect(viewModel.filteredNodesForOpenQuickly.allSatisfy { $0.filterResult != nil })
        #expect(viewModel.isFilteringForOpenQuickly)

        // Repeating the same query must reuse the materialized rows (same
        // instances, stable DifferenceKit identity), not build new ones.
        let firstPassRows = viewModel.filteredNodesForOpenQuickly
        searchStringRelay.accept("NeedleGenerated")
        // The list already shows the same 20 rows, so give the second
        // pass its full debounce window + match time before asserting
        // that it reused (rather than regrew) the materialized cache.
        try await Task.sleep(for: .milliseconds(600))
        let narrowedApplied = try await pollUntil(timeout: .seconds(10)) {
            viewModel.filteredNodesForOpenQuickly.count == expectedNeedleMatchCount
                && viewModel.filteredNodesForOpenQuickly.allSatisfy { $0.filterResult != nil }
        }
        #expect(narrowedApplied)
        #expect(viewModel.openQuicklyCellViewModelsByRowIndex.count == expectedNeedleMatchCount)
        #expect(Set(viewModel.filteredNodesForOpenQuickly.map(ObjectIdentifier.init))
            == Set(firstPassRows.map(ObjectIdentifier.init)))

        // Clearing empties the list and un-highlights the materialized
        // rows, but keeps the cache warm for the next search.
        searchStringRelay.accept("")
        let cleared = try await pollUntil(timeout: .seconds(10)) {
            viewModel.filteredNodesForOpenQuickly.isEmpty && !viewModel.isFilteringForOpenQuickly
        }
        #expect(cleared, "clearing the search never emptied the list")
        #expect(firstPassRows.allSatisfy { $0.filterResult == nil })
        #expect(viewModel.openQuicklyCellViewModelsByRowIndex.count == expectedNeedleMatchCount)

        // A reload invalidates the whole lazy state: objects, haystacks,
        // and materialized rows.
        viewModel.scheduleReload()
        let reloaded = try await pollUntil(timeout: .seconds(30)) {
            viewModel.loadState == .loaded && viewModel.openQuicklyCellViewModelsByRowIndex.isEmpty
        }
        #expect(reloaded, "reload never cleared the materialized row cache")

        withExtendedLifetime(mockRouter) {}
    }

    // MARK: - Fixtures

    private func makeFlatRuntimeObjects(count: Int) -> [RuntimeObject] {
        (0 ..< count).map { index in
            let displayName = index.isMultiple(of: 100)
                ? "TestFramework.NeedleGeneratedType\(index)"
                : "TestFramework.GeneratedType\(index)"
            return makeRuntimeObject(displayName: displayName)
        }
    }

    private func makeRuntimeObject(
        displayName: String,
        children: [RuntimeObject] = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: displayName,
            displayName: displayName,
            kind: .swift(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
            children: children,
            properties: []
        )
    }

    private func pollUntil(
        timeout: Duration,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if try await condition() {
                return true
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        return false
    }
}

/// Open Quickly list view model whose reload publishes a canned object
/// list instead of asking the engine, so tests control the data set while
/// still exercising the real `reloadData` path (the `isImageLoaded`
/// engine gate stays live).
@MainActor
private final class SeededOpenQuicklyListViewModel: SidebarRuntimeObjectListViewModel {
    private let seededRuntimeObjects: [RuntimeObject]

    init(
        seededRuntimeObjects: [RuntimeObject],
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>
    ) {
        self.seededRuntimeObjects = seededRuntimeObjects
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        seededRuntimeObjects
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { [seededRuntimeObjects] continuation in
            continuation.yield(.completed(seededRuntimeObjects))
            continuation.finish()
        }
    }
}
