import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("SidebarRootViewModel")
@MainActor
struct SidebarRootViewModelTests {
    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<SidebarRootRoute>()
    private let nodesSubject = BehaviorSubject<[RuntimeImageNode]>(value: [])
    private let clickedNodeRelay = PublishRelay<SidebarRootCellViewModel>()
    private let searchStringRelay = PublishRelay<String>()

    private let sharedCacheTree = Fixtures.imageTree(rootName: "Dyld Shared Cache", imagePaths: [TestImages.foundation])
    private let othersTree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])

    @Test("nodes mirror the source, one cell per root")
    func nodesMirrorSource() async throws {
        let (viewModel, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }

        nodesSubject.onNext([sharedCacheTree, othersTree])

        let roots = try await nextValue(from: output.nodes) { $0.count == 2 }
        #expect(roots.map(\.node.name) == ["Dyld Shared Cache", "Others"])
        #expect(roots[0].node === sharedCacheTree)
    }

    @Test("indexing exposes every node by root name and absolute path once nodesIndexed fires")
    func indexingExposesEveryNode() async throws {
        let (viewModel, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        async let indexed: Void = nextValue(from: output.nodesIndexed)
        try await settleMainQueue()

        nodesSubject.onNext([sharedCacheTree, othersTree])
        try await indexed

        let foundationLeaf = try #require(sharedCacheTree.leaf(forImagePath: TestImages.foundation))
        #expect(viewModel.allNodes["Dyld Shared Cache"]?.node === sharedCacheTree)
        #expect(viewModel.allNodes[foundationLeaf.absolutePath]?.node === foundationLeaf)
        #expect(viewModel.allNodes[othersTree.absolutePath]?.node === othersTree)
    }

    @Test("a search keeps only the roots whose subtree names contain it and reports the filter lifecycle")
    func searchFiltersRoots() async throws {
        let (viewModel, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        nodesSubject.onNext([sharedCacheTree, othersTree])
        _ = try await nextValue(from: output.nodes) { $0.count == 2 }
        async let began: Void = nextValue(from: output.didBeginFiltering)
        try await settleMainQueue()

        searchStringRelay.accept("libobjc")

        try await began
        let filtered = try await nextValue(from: output.nodes) { $0.count == 1 }
        #expect(filtered[0].node.name == "Others")
        #expect(viewModel.isFiltering)

        async let ended: Void = nextValue(from: output.didEndFiltering)
        try await settleMainQueue()
        searchStringRelay.accept("")

        try await ended
        _ = try await nextValue(from: output.nodes) { $0.count == 2 }
        #expect(viewModel.isFiltering == false)
    }

    @Test("clicking an image switches the document to that image")
    func clickingImageSwitchesDocument() async throws {
        let (viewModel, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        nodesSubject.onNext([sharedCacheTree])
        let roots = try await nextValue(from: output.nodes) { $0.count == 1 }
        let foundationCell = try #require(IteratorSequence(roots[0].makeIterator()).first { $0.isLeaf })

        clickedNodeRelay.accept(foundationCell)
        try await settleMainQueue()

        #expect(environment.documentState.currentImageNode === foundationCell.node)
        #expect(router.triggeredRoutes.isEmpty)
    }

    @Test("clicking a folder asks the outline to toggle it down to the configured depth")
    func clickingFolderTogglesExpansion() async throws {
        let (viewModel, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        nodesSubject.onNext([sharedCacheTree])
        let roots = try await nextValue(from: output.nodes) { $0.count == 1 }
        async let toggle = nextValue(from: output.toggleExpansion)
        try await settleMainQueue()

        clickedNodeRelay.accept(roots[0])

        let (item, maxDepth) = try await toggle
        #expect(item === roots[0])
        #expect(maxDepth == environment.settings.general.sidebarMaxExpansionDepth)
        #expect(environment.documentState.currentImageNode == nil)
    }

    // MARK: - Helpers

    private func makeViewModel() -> (SidebarRootViewModel, SidebarRootViewModel.Output) {
        let viewModel = environment.make {
            SidebarRootViewModel(documentState: environment.documentState, router: router, nodesSource: nodesSubject.asObservable())
        }
        let output = viewModel.transform(
            .init(
                clickedNode: clickedNodeRelay.asSignal(),
                selectedNode: .empty(),
                searchString: searchStringRelay.asSignal()
            )
        )
        return (viewModel, output)
    }
}
