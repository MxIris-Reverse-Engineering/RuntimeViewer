import AppKit
import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures
import Testing
@testable import RuntimeViewerApplication

/// Regression suite for the sidebar text-filter hot path
/// (`FilterEngine` + `SidebarRuntimeObjectFilterPipeline` over
/// `SidebarRuntimeObjectCellViewModel` trees).
///
/// History: before the 2026-08 filter overhaul, every (debounced)
/// keystroke reset `filterResult` on every row, whose didSet rebuilt the
/// attributed title unconditionally — 10,000 `NSAttributedString` rebuilds
/// per keystroke (20,000 on clear), ~3.5 s of main-thread freeze per
/// keystroke at N = 10k in a debug build. The emission-count assertions
/// below pin the fixed behavior: a keystroke may only rebuild titles for
/// rows whose highlight actually changed. Wall-clock prints are
/// informational; run with `--filter SidebarFilterPerformanceBaseline`
/// and look for `[baseline]` lines.
@Suite("SidebarFilterPerformanceBaseline", .serialized)
@MainActor
struct SidebarFilterPerformanceBaselineTests {
    private static let flatListCount = 10_000

    private static let treeParentCount = 2_000

    private static let treeChildrenPerParent = 4

    // MARK: - Flat list, default contains mode (sidebar default: filterMode == nil)

    @Test("flat list, default contains mode: keystrokes rebuild zero titles")
    func flatListDefaultModeKeystrokeCost() {
        let runtimeObjects = makeFlatRuntimeObjects(count: Self.flatListCount)

        var cellViewModels: [SidebarRuntimeObjectCellViewModel] = []
        measure("construct \(Self.flatListCount) flat cell view models") {
            cellViewModels = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
        }

        let counter = TitleRebuildCounter(observing: cellViewModels)
        let needleMatchCount = Self.flatListCount / 100

        // Broad query — the realistic first keystroke; matches every row.
        counter.reset()
        var broadMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("contains filter 'GeneratedType' (matches all rows)") {
            broadMatches = FilterEngine.filter(
                context: FilterContext(query: "GeneratedType", isCaseInsensitive: true, mode: nil),
                items: cellViewModels
            )
        }
        #expect(broadMatches.count == Self.flatListCount)
        // Contains mode carries no highlight, so no row's title changes.
        #expect(counter.titleRebuildCount == 0)

        // Narrow query — every 100th row carries the "Needle" marker.
        counter.reset()
        var narrowMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("contains filter 'Needle' (matches \(needleMatchCount) rows)") {
            narrowMatches = FilterEngine.filter(
                context: FilterContext(query: "Needle", isCaseInsensitive: true, mode: nil),
                items: cellViewModels
            )
        }
        #expect(narrowMatches.count == needleMatchCount)
        #expect(counter.titleRebuildCount == 0)

        // Miss — zero matches must cost zero rebuilds.
        counter.reset()
        var missMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("contains filter 'QQQQQQ' (matches 0 rows)") {
            missMatches = FilterEngine.filter(
                context: FilterContext(query: "QQQQQQ", isCaseInsensitive: true, mode: nil),
                items: cellViewModels
            )
        }
        #expect(missMatches.isEmpty)
        #expect(counter.titleRebuildCount == 0)

        // Clear — every row is already un-highlighted, so nothing rebuilds.
        counter.reset()
        var clearedMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("contains filter '' (clear search)") {
            clearedMatches = FilterEngine.filter(
                context: FilterContext(query: "", isCaseInsensitive: true, mode: nil),
                items: cellViewModels
            )
        }
        #expect(clearedMatches.count == Self.flatListCount)
        #expect(counter.titleRebuildCount == 0)
    }

    // MARK: - Flat list, fuzzy mode (Open Quickly configuration)

    @Test("flat list, fuzzy mode: rebuilds scale with matches, not rows")
    func flatListFuzzyModeKeystrokeCost() {
        let runtimeObjects = makeFlatRuntimeObjects(count: Self.flatListCount)

        var cellViewModels: [SidebarRuntimeObjectCellViewModel] = []
        measure("construct \(Self.flatListCount) flat cell view models (open quickly)") {
            cellViewModels = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: true) }
        }

        let counter = TitleRebuildCounter(observing: cellViewModels)

        // Narrow fuzzy query: only the matched rows gain a highlight.
        counter.reset()
        var narrowMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("fuzzy filter 'Needle' over \(Self.flatListCount) rows") {
            narrowMatches = FilterEngine.filter(
                context: FilterContext(query: "Needle", isCaseInsensitive: false, mode: .fuzzySearch),
                items: cellViewModels
            )
        }
        #expect(!narrowMatches.isEmpty)
        #expect(counter.titleRebuildCount == narrowMatches.count)
        print("[baseline] fuzzy narrow: \(narrowMatches.count) matches, \(counter.titleRebuildCount) title rebuilds")

        // Broad fuzzy query — every matched row genuinely changes
        // highlight, so this transition legitimately pays per-match.
        counter.reset()
        var broadMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("fuzzy filter 'Type' over \(Self.flatListCount) rows") {
            broadMatches = FilterEngine.filter(
                context: FilterContext(query: "Type", isCaseInsensitive: false, mode: .fuzzySearch),
                items: cellViewModels
            )
        }
        #expect(!broadMatches.isEmpty)
        #expect(counter.titleRebuildCount == broadMatches.count)
        print("[baseline] fuzzy broad: \(broadMatches.count) matches, \(counter.titleRebuildCount) title rebuilds")

        // Clear after a broad match: every highlighted row must un-highlight
        // (real work), but no more than that.
        counter.reset()
        measure("fuzzy filter '' (clear search)") {
            _ = FilterEngine.filter(
                context: FilterContext(query: "", isCaseInsensitive: false, mode: .fuzzySearch),
                items: cellViewModels
            )
        }
        #expect(counter.titleRebuildCount == broadMatches.count)
        print("[baseline] fuzzy clear title rebuilds: \(counter.titleRebuildCount)")
    }

    // MARK: - Tree (parents with children): didSet cascade cost

    @Test("tree: contains-mode keystrokes rebuild zero titles")
    func treeCascadeKeystrokeCost() {
        let runtimeObjects = makeTreeRuntimeObjects(
            parentCount: Self.treeParentCount,
            childrenPerParent: Self.treeChildrenPerParent
        )
        let totalNodeCount = Self.treeParentCount * (1 + Self.treeChildrenPerParent)

        var parentCellViewModels: [SidebarRuntimeObjectCellViewModel] = []
        measure("construct \(totalNodeCount) tree cell view models") {
            parentCellViewModels = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
        }

        let allCellViewModels = flatten(parentCellViewModels)
        #expect(allCellViewModels.count == totalNodeCount)
        let counter = TitleRebuildCounter(observing: allCellViewModels)
        let needleParentCount = Self.treeParentCount / 100

        // Narrow query hitting children only: the parent survives because
        // its haystack (`currentAndChildrenNames`) embeds descendant names.
        counter.reset()
        var narrowMatches: [SidebarRuntimeObjectCellViewModel] = []
        measure("tree contains filter 'Needle' (\(needleParentCount) parents survive)") {
            narrowMatches = FilterEngine.filter(
                context: FilterContext(query: "Needle", isCaseInsensitive: true, mode: nil),
                items: parentCellViewModels
            )
        }
        #expect(narrowMatches.count == needleParentCount)
        #expect(counter.titleRebuildCount == 0)

        counter.reset()
        measure("tree contains filter 'QQQQQQ' (matches 0)") {
            _ = FilterEngine.filter(
                context: FilterContext(query: "QQQQQQ", isCaseInsensitive: true, mode: nil),
                items: parentCellViewModels
            )
        }
        #expect(counter.titleRebuildCount == 0)

        counter.reset()
        measure("tree contains filter '' (clear search)") {
            _ = FilterEngine.filter(
                context: FilterContext(query: "", isCaseInsensitive: true, mode: nil),
                items: parentCellViewModels
            )
        }
        #expect(counter.titleRebuildCount == 0)
    }

    // MARK: - Case sensitivity (regression for the inverted flag)

    @Test("contains mode honors the case-insensitive flag")
    func containsModeHonorsCaseInsensitiveFlag() {
        // Pre-fix, the branch was inverted: `isCaseInsensitive == true`
        // ran a case-SENSITIVE `contains`. These assertions fail on the
        // old implementation.
        let haystacks = ["TestFramework.NeedleGeneratedType0"]

        let caseInsensitiveMatches = FilterEngine.match(
            FilterContext(query: "needle", isCaseInsensitive: true, mode: nil),
            haystacks: haystacks
        )
        #expect(caseInsensitiveMatches.count == 1)

        let caseSensitiveMatches = FilterEngine.match(
            FilterContext(query: "needle", isCaseInsensitive: false, mode: nil),
            haystacks: haystacks
        )
        #expect(caseSensitiveMatches.isEmpty)

        let caseSensitiveExactMatches = FilterEngine.match(
            FilterContext(query: "Needle", isCaseInsensitive: false, mode: nil),
            haystacks: haystacks
        )
        #expect(caseSensitiveExactMatches.count == 1)
    }

    // MARK: - Pipeline parity with the single-level cascade

    @Test("pipeline output matches the mutating cascade level by level")
    func pipelineMatchesMutatingCascade() throws {
        let scope = RuntimeObjectScope(generic: .only)
        let contexts = [
            FilterContext(query: "Needle", isCaseInsensitive: true, mode: nil),
            FilterContext(query: "Needle", isCaseInsensitive: false, mode: .fuzzySearch),
            FilterContext(query: "", isCaseInsensitive: true, mode: nil),
        ]
        for context in contexts {
            for activeScope in [RuntimeObjectScope(), scope] {
                let runtimeObjects = makeTreeRuntimeObjects(parentCount: 200, childrenPerParent: 3)
                let pipelineCells = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
                let cascadeCells = runtimeObjects.map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }

                // Pipeline path (what the view model runs).
                let snapshotForest = SidebarRuntimeObjectFilterPipeline.snapshot(of: pipelineCells, scope: activeScope)
                let verdictForest = SidebarRuntimeObjectFilterPipeline.verdicts(for: snapshotForest, context: context)
                let pipelineFiltered = try #require(
                    SidebarRuntimeObjectFilterPipeline.apply(verdictForest, to: pipelineCells, context: context, scope: activeScope)
                )

                // Reference path: the legacy per-level cascade semantics via
                // the mutating wrapper (independent recursion, same matcher).
                for cell in cascadeCells {
                    applyScopeToTreeForReference(cell, scope: activeScope)
                }
                let scopedCascadeCells = activeScope.isActive
                    ? cascadeCells.filter { $0.matchesScopeRecursively(activeScope) }
                    : cascadeCells
                let cascadeFiltered = FilterEngine.filter(context: context, items: scopedCascadeCells)

                #expect(
                    displayNameTree(of: pipelineFiltered) == displayNameTree(of: cascadeFiltered),
                    "mode: \(String(describing: context.mode)), query: '\(context.query)', scopeActive: \(activeScope.isActive)"
                )
                #expect(
                    highlightTree(of: pipelineFiltered) == highlightTree(of: cascadeFiltered),
                    "mode: \(String(describing: context.mode)), query: '\(context.query)', scopeActive: \(activeScope.isActive)"
                )
            }
        }
    }

    // MARK: - Haystack cache invalidation

    @Test("splicing a child invalidates cached haystacks up the ancestor chain")
    func splicedChildInvalidatesAncestorHaystacks() throws {
        let grandchild = makeRuntimeObject(displayName: "TestFramework.Parent.Child.Grandchild")
        let child = makeRuntimeObject(displayName: "TestFramework.Parent.Child", children: [grandchild])
        let parent = makeRuntimeObject(displayName: "TestFramework.Parent", children: [child])
        let parentCellViewModel = SidebarRuntimeObjectCellViewModel(runtimeObject: parent, forOpenQuickly: false)
        let childCellViewModel = try #require(parentCellViewModel.children.first)

        // Warm every level's cache.
        #expect(parentCellViewModel.currentAndChildrenNames.contains("Grandchild"))
        #expect(childCellViewModel.currentAndChildrenNames.contains("Grandchild"))

        let splicedChild = makeRuntimeObject(displayName: "TestFramework.Parent.Child.SplicedNeedle")
        #expect(childCellViewModel.appendRuntimeObjectChildPreservingCurrentDescendants(splicedChild))

        // Both the mutated cell and its ancestor must see the new name.
        #expect(childCellViewModel.currentAndChildrenNames.contains("SplicedNeedle"))
        #expect(parentCellViewModel.currentAndChildrenNames.contains("SplicedNeedle"))
    }

    // MARK: - View model end-to-end (MockRouter + seeded reload + debounced search)

    @Test("view model end-to-end: seeded reload and debounced search")
    func viewModelEndToEndSearch() async throws {
        // The seeded view model subscribes to the shared local engine's
        // data-change broadcasts; a concurrent suite firing a real
        // `.fullReload` (the interface-cache flush test) would reload the
        // fixture and reset the search state mid-assertion. Hold the
        // cross-suite lock (see SharedLocalEngineTestLock.swift).
        try await withSharedLocalEngineLock {
            try await runViewModelEndToEndSearch()
        }
    }

    private func runViewModelEndToEndSearch() async throws {
        let localRuntimeEngine = RuntimeEngine.local

        // Wait for the local engine to publish the test process's image list.
        var imageList: [String] = []
        let engineReady = try await pollUntil(timeout: .seconds(15)) {
            imageList = await localRuntimeEngine.imageList
            return !imageList.isEmpty
        }
        #expect(engineReady, "local engine never published an image list")
        let loadedImagePath = try #require(
            imageList.first { $0.hasSuffix("/Foundation") } ?? imageList.first
        )

        // Build a RuntimeImageNode whose `path` resolves to a genuinely
        // loaded image so `reloadData`'s `isImageLoaded` gate passes.
        let rootImageNode = RuntimeImageNode.rootNode(for: [loadedImagePath], name: "Root")
        var imageNode = rootImageNode
        while let firstChild = imageNode.children.first {
            imageNode = firstChild
        }
        #expect(imageNode.path == loadedImagePath)

        let documentState = DocumentState()
        let mockRouter = MockRouter<SidebarRuntimeObjectRoute>()
        let seededRuntimeObjects = makeFlatRuntimeObjects(count: Self.flatListCount)

        let reloadClock = ContinuousClock()
        let reloadStart = reloadClock.now
        let viewModel = SeededSidebarRuntimeObjectViewModel(
            seededRuntimeObjects: seededRuntimeObjects,
            imageNode: imageNode,
            documentState: documentState,
            router: mockRouter
        )
        let reloadFinished = try await pollUntil(timeout: .seconds(30)) {
            viewModel.loadState == .loaded
        }
        print("[baseline] seeded reload (engine gate + \(Self.flatListCount) cell view models): \(millisecondsDescription(of: reloadClock.now - reloadStart))")
        #expect(reloadFinished, "seeded reload never reached .loaded")
        #expect(viewModel.filteredNodes.count == Self.flatListCount)

        let searchStringRelay = PublishRelay<String>()
        let input = SidebarRuntimeObjectViewModel.Input(
            runtimeObjectClicked: .never(),
            runtimeObjectOpenedInNewTab: .never(),
            loadImageClicked: .never(),
            searchString: searchStringRelay.asDriver(onErrorJustReturn: ""),
            isSearchCaseSensitive: .just(false)
        )
        _ = viewModel.transform(input)

        // One keystroke through the real pipeline. The measured time
        // includes the 150 ms coalescing delay, the off-main match, and
        // the poll granularity.
        let expectedNeedleCount = Self.flatListCount / 100
        let searchStart = reloadClock.now
        searchStringRelay.accept("Needle")
        let searchApplied = try await pollUntil(timeout: .seconds(10)) {
            viewModel.filteredNodes.count == expectedNeedleCount
        }
        print("[baseline] end-to-end 'Needle' search (includes 150 ms coalescing delay): \(millisecondsDescription(of: reloadClock.now - searchStart))")
        #expect(searchApplied, "debounced search never produced \(expectedNeedleCount) filtered nodes")

        // Clearing the search must restore the full list (fast path).
        searchStringRelay.accept("")
        let searchCleared = try await pollUntil(timeout: .seconds(10)) {
            viewModel.filteredNodes.count == Self.flatListCount
        }
        #expect(searchCleared, "clearing the search never restored the full list")

        // The search path must not navigate anywhere.
        #expect(mockRouter.triggeredRoutes.isEmpty)

        // The view model holds its router unowned — keep the mock alive
        // until every assertion has run.
        withExtendedLifetime(mockRouter) {}
    }

    // MARK: - Fixtures

    /// Deterministic flat list: every 100th object carries the "Needle"
    /// marker so narrow queries have a fixed match set, and every object
    /// shares the "GeneratedType" stem so broad queries match the whole
    /// list.
    private func makeFlatRuntimeObjects(count: Int) -> [RuntimeObject] {
        (0 ..< count).map { index in
            let displayName = index.isMultiple(of: 100)
                ? "TestFramework.NeedleGeneratedType\(index)"
                : "TestFramework.GeneratedType\(index)"
            return makeRuntimeObject(displayName: displayName)
        }
    }

    /// Deterministic tree: `parentCount` parents with `childrenPerParent`
    /// children each. Every 100th parent's first child carries the
    /// "Needle" marker (so narrow queries only survive through the
    /// parent's descendant haystack), and every 3rd parent is generic
    /// (so scope-constrained runs prune a deterministic subset).
    private func makeTreeRuntimeObjects(parentCount: Int, childrenPerParent: Int) -> [RuntimeObject] {
        (0 ..< parentCount).map { parentIndex in
            let children = (0 ..< childrenPerParent).map { childIndex -> RuntimeObject in
                let marker = (parentIndex.isMultiple(of: 100) && childIndex == 0) ? "Needle" : ""
                return makeRuntimeObject(
                    displayName: "TestFramework.GeneratedParent\(parentIndex).\(marker)Child\(childIndex)"
                )
            }
            return makeRuntimeObject(
                displayName: "TestFramework.GeneratedParent\(parentIndex)",
                children: children,
                properties: parentIndex.isMultiple(of: 3) ? [.isGeneric] : []
            )
        }
    }

    private func makeRuntimeObject(
        displayName: String,
        children: [RuntimeObject] = [],
        properties: RuntimeObject.Properties = []
    ) -> RuntimeObject {
        RuntimeObject(
            name: displayName,
            displayName: displayName,
            kind: .swift(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
            children: children,
            properties: properties
        )
    }

    private func flatten(_ cellViewModels: [SidebarRuntimeObjectCellViewModel]) -> [SidebarRuntimeObjectCellViewModel] {
        cellViewModels.flatMap { [$0] + flatten($0.children) }
    }

    /// Reference-path helper replicating the legacy tree-wide scope
    /// cascade: push the scope into every cell depth-first so each cell's
    /// stored scope is in place before the text filter cascades. The
    /// subsequent `FilterEngine.filter` call re-derives every level's
    /// `_filteredChildren` under this scope (all reference contexts differ
    /// from the cells' default context, so the cascade is guaranteed to
    /// fire).
    private func applyScopeToTreeForReference(_ cell: SidebarRuntimeObjectCellViewModel, scope: RuntimeObjectScope) {
        for child in cell.unfilteredChildren {
            applyScopeToTreeForReference(child, scope: scope)
        }
        cell.scope = scope
    }

    /// Nested display-name structure of the *filtered* tree, for
    /// order-sensitive equality between the pipeline and cascade paths.
    private func displayNameTree(of cellViewModels: [SidebarRuntimeObjectCellViewModel]) -> [String] {
        cellViewModels.flatMap { cellViewModel -> [String] in
            [cellViewModel.runtimeObject.displayName] + displayNameTree(of: cellViewModel.children).map { "  " + $0 }
        }
    }

    /// Which filtered nodes carry a highlight, in display order.
    private func highlightTree(of cellViewModels: [SidebarRuntimeObjectCellViewModel]) -> [Bool] {
        cellViewModels.flatMap { cellViewModel -> [Bool] in
            [cellViewModel.filterResult != nil] + highlightTree(of: cellViewModel.children)
        }
    }

    // MARK: - Measurement helpers

    @discardableResult
    private func measure(_ label: String, _ body: () -> Void) -> Duration {
        let duration = ContinuousClock().measure(body)
        print("[baseline] \(label): \(millisecondsDescription(of: duration))")
        return duration
    }

    private func millisecondsDescription(of duration: Duration) -> String {
        let totalMilliseconds = Double(duration.components.seconds) * 1_000
            + Double(duration.components.attoseconds) / 1e15
        return String(format: "%.2f ms", totalMilliseconds)
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

/// Counts `$appearance` relay emissions across a set of cell view models.
/// `@RxObserved` is backed by a `BehaviorRelay`, so every `filterResult`
/// didSet that changes the published appearance lands here synchronously —
/// the counts asserted above are exact, not scheduler-delayed. Since
/// proposal 0005 the appearance is a single deduplicated stream: an
/// emission during a filter pass means the attributed title actually
/// changed (icons are untouched by filtering), so the counter still
/// measures exactly the title rebuilds the suite pins.
@MainActor
private final class TitleRebuildCounter {
    private(set) var titleRebuildCount = 0

    private let disposeBag = DisposeBag()

    init(observing cellViewModels: [SidebarRuntimeObjectCellViewModel]) {
        for cellViewModel in cellViewModels {
            cellViewModel.$appearance
                .skip(1) // BehaviorRelay replays the current appearance on subscribe
                .subscribeOnNext { [weak self] _ in
                    guard let self else { return }
                    titleRebuildCount += 1
                }
                .disposed(by: disposeBag)
        }
    }

    func reset() {
        titleRebuildCount = 0
    }
}

/// Sidebar view model whose reload publishes a canned object list instead
/// of asking the engine, so end-to-end tests control the data set while
/// still exercising the real `reloadData` / filter pipeline (the
/// `isImageLoaded` engine gate stays live).
@MainActor
private final class SeededSidebarRuntimeObjectViewModel: SidebarRuntimeObjectViewModel {
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
}
