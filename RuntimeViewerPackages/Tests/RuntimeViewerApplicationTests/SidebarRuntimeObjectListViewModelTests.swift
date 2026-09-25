import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The public contract of the object list against a real image. The filter
/// pipeline's cost model, Open Quickly's lazy materialization and reload
/// invalidation are pinned separately with seeded subclasses.
@Suite("SidebarRuntimeObjectListViewModel")
@MainActor
struct SidebarRuntimeObjectListViewModelTests {
    private let router = MockRouter<SidebarRuntimeObjectRoute>()
    private let runtimeObjectClickedRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()
    private let runtimeObjectOpenedInNewTabRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()
    private let searchStringRelay = BehaviorRelay<String>(value: "")
    private let openQuicklyClickedRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()
    private let openQuicklySearchRelay = PublishRelay<String>()
    private let addBookmarkRelay = PublishRelay<SidebarRuntimeObjectCellViewModel>()

    // MARK: - findCell (pure)

    @Test("findCell returns the matching cell together with its ancestors, outermost first")
    func findCellReportsAncestors() throws {
        let environment = ViewModelTestEnvironment()
        let leaf = Fixtures.runtimeObject(name: "Outer.Inner.Leaf")
        let inner = Fixtures.runtimeObject(name: "Outer.Inner", children: [leaf])
        let outer = Fixtures.runtimeObject(name: "Outer", children: [inner])
        let outerCell = environment.make { SidebarRuntimeObjectCellViewModel(runtimeObject: outer, forOpenQuickly: false) }

        let lookup = try #require(SidebarRuntimeObjectListViewModel.findCell(for: leaf, in: [outerCell]))
        #expect(lookup.cell.runtimeObject == leaf)
        #expect(lookup.ancestors.map(\.runtimeObject.name) == ["Outer", "Outer.Inner"])
        #expect(SidebarRuntimeObjectListViewModel.findCell(for: Fixtures.runtimeObject(name: "Missing"), in: [outerCell]) == nil)
    }

    // MARK: - Engine-backed

    @Test("loads the image's objects, name-sorted inside kind sections")
    func loadsSortedSections() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }

        let rows = try await harness.loadedRows()
        #expect(rows.contains { $0.runtimeObject.name == "NSObject" && $0.runtimeObject.kind == .objc(.type(.class)) })

        let sections = try await nextValue(from: harness.baseOutput.runtimeObjectSections) { !$0.isEmpty }
        #expect(sections.map(\.kind) == sections.map(\.kind).sorted())
        #expect(sections.reduce(0) { $0 + $1.objects.count } == rows.count)
        for section in sections {
            #expect(section.objects.allSatisfy { $0.runtimeObject.kind == section.kind })
            let names = section.objects.map(\.runtimeObject.displayName)
            #expect(names == names.sorted())
        }
    }

    @Test("a search string narrows the rows to substring matches once the coalescing window elapses")
    func searchNarrowsRows() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let fullCount = try await harness.loadedRows().count

        searchStringRelay.accept("NSObject")

        let narrowed = try await nextValue(from: harness.baseOutput.runtimeObjects) { rows in
            !rows.isEmpty && rows.count < fullCount
        }
        #expect(narrowed.allSatisfy { $0.filterableString.localizedCaseInsensitiveContains("NSObject") })
        #expect(harness.viewModel.isFiltering)

        searchStringRelay.accept("")

        _ = try await nextValue(from: harness.baseOutput.runtimeObjects) { $0.count == fullCount }
        #expect(harness.viewModel.isFiltering == false)
    }

    @Test("a scope hides every object outside its included kinds")
    func scopeHidesOtherKinds() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await harness.loadedRows()

        var protocolsOnly = RuntimeObjectScope()
        protocolsOnly.includedKinds = [.objc(.type(.protocol))]
        harness.viewModel.$scope.accept(protocolsOnly)

        let scoped = try await nextValue(from: harness.baseOutput.runtimeObjects) { rows in
            !rows.isEmpty && rows.allSatisfy { $0.runtimeObject.kind == .objc(.type(.protocol)) }
        }
        #expect(scoped.contains { $0.runtimeObject.name == "NSObject" })
        #expect(harness.viewModel.isFiltering)
    }

    @Test("selectCell resolves the document's selected object to its sidebar cell")
    func selectCellResolvesSelection() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()
        async let lookup = nextValue(from: harness.listOutput.selectCell, timeout: 60)
        try await settleMainQueue()

        harness.environment.documentState.selectionRouter.trigger(.push(nsObject))

        let resolved = try await lookup
        #expect(resolved.cell.runtimeObject == nsObject)
        #expect(resolved.ancestors.isEmpty)
    }

    @Test("Open Quickly filters its own flat list with fuzzy matching")
    func openQuicklyFiltersFlatList() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await harness.loadedRows()

        openQuicklySearchRelay.accept("")
        openQuicklySearchRelay.accept("NSObj")

        let matches = try await nextValue(from: harness.listOutput.runtimeObjectsForOpenQuickly) { !$0.isEmpty }
        #expect(matches.contains { $0.runtimeObject.name == "NSObject" })
        #expect(matches.allSatisfy { $0.forOpenQuickly })
        #expect(harness.viewModel.isFilteringForOpenQuickly)
    }

    @Test("clicking a row pushes its object, and opening in a new tab adds a tab")
    func clickingRowsNavigates() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObjectCell = try await harness.nsObjectCell()

        runtimeObjectClickedRelay.accept(nsObjectCell)
        try await settleMainQueue()
        #expect(harness.environment.documentState.selectedRuntimeObject == nsObjectCell.runtimeObject)

        runtimeObjectOpenedInNewTabRelay.accept(nsObjectCell)
        try await settleMainQueue()
        #expect(harness.environment.documentState.tabs.count == 2)
        #expect(harness.environment.documentState.activeTab?.object == nsObjectCell.runtimeObject)

        // Park the document on an empty tab so the Open Quickly click has
        // something observable to change.
        harness.environment.documentState.selectionRouter.trigger(.newTab)
        #expect(harness.environment.documentState.selectedRuntimeObject == nil)

        openQuicklyClickedRelay.accept(nsObjectCell)
        try await settleMainQueue()
        #expect(harness.environment.documentState.selectedRuntimeObject == nsObjectCell.runtimeObject)
        #expect(router.triggeredRoutes.isEmpty)
    }

    @Test("adding a bookmark stores the object under the engine's bookmark scope and image")
    func addingBookmarkStoresObject() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObjectCell = try await harness.nsObjectCell()

        addBookmarkRelay.accept(nsObjectCell)
        try await settleMainQueue()

        let scopeKey = harness.environment.documentState.runtimeEngine.bookmarkScope.bookmarkKey
        let stored = harness.environment.appDefaults.objectBookmarksByScopeAndImagePath[scopeKey]?[TestImages.libobjc] ?? []
        #expect(stored.map(\.object) == [nsObjectCell.runtimeObject])
    }

    // MARK: - Reveal in Sidebar Navigator

    /// The follow behind `selectCell` fires only when the selection changes;
    /// the command is usually run for the object that is already selected.
    @Test("a reveal answers every request, including for the object already selected")
    func revealAnswersRepeatedRequests() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()
        harness.environment.documentState.selectionRouter.trigger(.push(nsObject))

        for _ in 0 ..< 2 {
            async let revealed = nextValue(from: harness.listOutput.revealCell)
            try await settleMainQueue()

            harness.viewModel.revealSelectedRuntimeObject()

            let lookup = try await revealed
            #expect(lookup.cell.runtimeObject == nsObject)
            #expect(lookup.ancestors.isEmpty)
        }
    }

    @Test("a search text that hides the row is cleared before the reveal")
    func revealClearsHidingSearchText() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()
        harness.environment.documentState.selectionRouter.trigger(.push(nsObject))
        searchStringRelay.accept("NoRuntimeObjectIsNamedLikeThis")
        _ = try await nextValue(from: harness.baseOutput.runtimeObjects) { rows in
            !rows.contains { $0.runtimeObject == nsObject }
        }

        async let cleared: Void = nextValue(from: harness.baseOutput.filterCleared)
        async let revealed = nextValue(from: harness.listOutput.revealCell)
        try await settleMainQueue()

        harness.viewModel.revealSelectedRuntimeObject()

        try await cleared
        let lookup = try await revealed
        #expect(lookup.cell.runtimeObject == nsObject)
        #expect(harness.viewModel.searchString.isEmpty)
        #expect(harness.viewModel.isFiltering == false)
        #expect(harness.viewModel.filteredNodes.contains { $0.runtimeObject == nsObject })
    }

    @Test("a scope that hides the row is reset before the reveal")
    func revealResetsHidingScope() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let nsObject = try await harness.nsObject()
        harness.environment.documentState.selectionRouter.trigger(.push(nsObject))
        var protocolsOnly = RuntimeObjectScope()
        protocolsOnly.includedKinds = [.objc(.type(.protocol))]
        harness.viewModel.$scope.accept(protocolsOnly)
        _ = try await nextValue(from: harness.baseOutput.runtimeObjects) { rows in
            !rows.isEmpty && rows.allSatisfy { $0.runtimeObject.kind == .objc(.type(.protocol)) }
        }

        async let revealed = nextValue(from: harness.listOutput.revealCell)
        try await settleMainQueue()

        harness.viewModel.revealSelectedRuntimeObject()

        let lookup = try await revealed
        #expect(lookup.cell.runtimeObject == nsObject)
        #expect(harness.viewModel.scope.isActive == false)
        #expect(harness.viewModel.isFiltering == false)
    }

    @Test("a request made before the list has loaded is answered once it has")
    func revealWaitsForTheLoad() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let nsObject = try await engine.runtimeObject(named: "NSObject", kind: .objc(.type(.class)), in: TestImages.libobjc)
        let harness = try await makeHarness(showing: nsObject)
        defer { withExtendedLifetime(harness.viewModel) {} }
        // Subscribed synchronously rather than through `nextValue`, which only
        // subscribes once this test suspends: the output is cold, so a request
        // sent before anyone listens goes nowhere.
        var revealedCells: [RuntimeObject] = []
        let subscription = harness.listOutput.revealCell.emitOnNext { revealedCells.append($0.cell.runtimeObject) }
        defer { subscription.dispose() }
        // Nothing has suspended since the view model was built, so its first
        // reload has not even started: this request has to wait.
        #expect(harness.viewModel.loadState != .loaded)

        harness.viewModel.revealSelectedRuntimeObject()

        let answered = await pollUntil(timeout: .seconds(60)) { !revealedCells.isEmpty }
        #expect(answered, "the request made before the load was never answered; loadState=\(harness.viewModel.loadState)")
        #expect(revealedCells == [nsObject])
    }

    /// Clearing the filter first would cost the user their filter and still
    /// find nothing.
    @Test("an object the list does not contain fails the reveal and keeps the filter")
    func revealOfAMissingObjectFails() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        let fullCount = try await harness.loadedRows().count
        let missingObject = Fixtures.runtimeObject(name: "NoSuchClass", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)
        harness.environment.documentState.selectionRouter.trigger(.push(missingObject))
        searchStringRelay.accept("NSObject")
        _ = try await nextValue(from: harness.baseOutput.runtimeObjects) { rows in
            !rows.isEmpty && rows.count < fullCount
        }

        async let failed: Void = nextValue(from: harness.listOutput.revealFailed)
        async let revealedCells = values(from: harness.listOutput.revealCell, during: 0.5)
        try await settleMainQueue()

        harness.viewModel.revealSelectedRuntimeObject()

        try await failed
        #expect(try await revealedCells.isEmpty)
        #expect(harness.viewModel.searchString == "NSObject")
        #expect(harness.viewModel.isFiltering)
    }

    @Test("with nothing on screen a reveal request is ignored")
    func revealWithoutAnObjectIsIgnored() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await harness.loadedRows()

        async let revealedCells = values(from: harness.listOutput.revealCell, during: 0.5)
        async let failures: [Void] = values(from: harness.listOutput.revealFailed, during: 0.5)
        try await settleMainQueue()

        harness.viewModel.revealSelectedRuntimeObject()

        #expect(try await revealedCells.isEmpty)
        #expect(try await failures.isEmpty)
    }

    // MARK: - Helpers

    private struct Harness {
        let environment: ViewModelTestEnvironment
        let viewModel: SidebarRuntimeObjectListViewModel
        let baseOutput: SidebarRuntimeObjectViewModel.Output
        let listOutput: SidebarRuntimeObjectListViewModel.Output

        func loadedRows() async throws -> [SidebarRuntimeObjectCellViewModel] {
            try await nextValue(from: baseOutput.runtimeObjects, timeout: 60) { !$0.isEmpty }
        }

        func nsObjectCell() async throws -> SidebarRuntimeObjectCellViewModel {
            let rows = try await loadedRows()
            return try #require(rows.first { $0.runtimeObject.name == "NSObject" && $0.runtimeObject.kind == .objc(.type(.class)) })
        }

        func nsObject() async throws -> RuntimeObject {
            try await nsObjectCell().runtimeObject
        }
    }

    /// - Parameter runtimeObject: Put on screen before the view model exists,
    ///   so the view model is built — and its first reload scheduled — with
    ///   no suspension point in between.
    private func makeHarness(showing runtimeObject: RuntimeObject? = nil) async throws -> Harness {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        if let runtimeObject {
            environment.documentState.selectionRouter.trigger(.push(runtimeObject))
        }
        let tree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        let leaf = try #require(tree.leaf(forImagePath: TestImages.libobjc))
        let viewModel = environment.make {
            SidebarRuntimeObjectListViewModel(imageNode: leaf, documentState: environment.documentState, router: router)
        }
        let baseOutput = viewModel.transform(
            SidebarRuntimeObjectViewModel.Input(
                runtimeObjectClicked: runtimeObjectClickedRelay.asSignal(),
                runtimeObjectOpenedInNewTab: runtimeObjectOpenedInNewTabRelay.asSignal(),
                loadImageClicked: .empty(),
                searchString: searchStringRelay.asDriver(),
                isSearchCaseSensitive: .just(false)
            )
        )
        let listOutput = viewModel.transform(
            SidebarRuntimeObjectListViewModel.Input(
                runtimeObjectClickedForOpenQuickly: openQuicklyClickedRelay.asSignal(),
                searchStringForOpenQuickly: openQuicklySearchRelay.asSignal(),
                addBookmark: addBookmarkRelay.asSignal()
            )
        )
        return Harness(environment: environment, viewModel: viewModel, baseOutput: baseOutput, listOutput: listOutput)
    }
}
