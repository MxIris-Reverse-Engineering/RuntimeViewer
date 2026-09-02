import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("SidebarRootBookmarkViewModel")
@MainActor
struct SidebarRootBookmarkViewModelTests {
    private let environment = ViewModelTestEnvironment()
    private let router = MockRouter<SidebarRootRoute>()
    private let moveBookmarkRelay = PublishRelay<OutlineMove>()
    private let removeBookmarkRelay = PublishRelay<Int>()
    private let searchStringRelay = PublishRelay<String>()

    /// A peer that is not the document's engine; its bookmarks must never show.
    private let otherScopeKey = RuntimeBookmarkScope.identified(.directTCP(port: 2, host: "127.0.0.1", role: .client)).bookmarkKey

    private var documentScopeKey: String {
        environment.documentState.runtimeEngine.bookmarkScope.bookmarkKey
    }

    @Test("nodes list the bookmarks stored for the document's scope only")
    func nodesListCurrentScopeBookmarks() async throws {
        try seedBookmarks()
        let (viewModel, _, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }

        let roots = try await nextValue(from: viewModel.$nodes) { !$0.isEmpty }
        #expect(roots.map(\.node.name) == ["Foundation", "libobjc.A.dylib"])
        #expect(try await nextValue(from: output.isBookmarkEmpty) == false)
    }

    @Test("removing a bookmark drops that row and reports emptiness once the last one goes")
    func removingBookmarkDropsRow() async throws {
        try seedBookmarks()
        let (viewModel, _, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await nextValue(from: viewModel.$nodes) { $0.count == 2 }

        removeBookmarkRelay.accept(0)
        _ = try await nextValue(from: viewModel.$nodes) { $0.map(\.node.name) == ["libobjc.A.dylib"] }

        removeBookmarkRelay.accept(0)
        _ = try await nextValue(from: viewModel.$nodes) { $0.isEmpty }
        #expect(try await nextValue(from: output.isBookmarkEmpty) { $0 } == true)
        #expect(environment.appDefaults.imageBookmarksByScope[otherScopeKey]?.count == 1)
    }

    @Test("moving a bookmark reorders the stored list")
    func movingBookmarkReorders() async throws {
        try seedBookmarks()
        let (viewModel, _, _) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await nextValue(from: viewModel.$nodes) { $0.count == 2 }

        moveBookmarkRelay.accept(
            OutlineMove(sourceParentPath: nil, sourceIndexes: [0], destinationParentPath: nil, destinationIndex: 2, isDropOnItem: false)
        )

        _ = try await nextValue(from: viewModel.$nodes) { $0.map(\.node.name) == ["libobjc.A.dylib", "Foundation"] }
        #expect(environment.appDefaults.imageBookmarksByScope[documentScopeKey]?.map(\.imageNode.name) == ["libobjc.A.dylib", "Foundation"])
    }

    @Test("moving is disabled while a search filter is active")
    func movingDisabledWhileFiltering() async throws {
        try seedBookmarks()
        let (viewModel, _, output) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await nextValue(from: viewModel.$nodes) { $0.count == 2 }
        #expect(try await nextValue(from: output.isMoveBookmarkEnabled) == true)

        searchStringRelay.accept("Foundation")

        #expect(try await nextValue(from: output.isMoveBookmarkEnabled) { !$0 } == false)
    }

    // MARK: - Helpers

    private func seedBookmarks() throws {
        let foundationTree = Fixtures.imageTree(rootName: "Dyld Shared Cache", imagePaths: [TestImages.foundation])
        let libobjcTree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        let foundationLeaf = try #require(foundationTree.leaf(forImagePath: TestImages.foundation))
        let libobjcLeaf = try #require(libobjcTree.leaf(forImagePath: TestImages.libobjc))
        environment.appDefaults.imageBookmarksByScope = [
            documentScopeKey: [
                RuntimeImageBookmark(imageNode: foundationLeaf),
                RuntimeImageBookmark(imageNode: libobjcLeaf),
            ],
            otherScopeKey: [
                RuntimeImageBookmark(imageNode: foundationLeaf),
            ],
        ]
    }

    private func makeViewModel() -> (SidebarRootBookmarkViewModel, SidebarRootViewModel.Output, SidebarRootBookmarkViewModel.Output) {
        let viewModel = environment.make {
            SidebarRootBookmarkViewModel(documentState: environment.documentState, router: router)
        }
        let baseOutput = viewModel.transform(
            SidebarRootViewModel.Input(clickedNode: .empty(), selectedNode: .empty(), searchString: searchStringRelay.asSignal())
        )
        let output = viewModel.transform(
            SidebarRootBookmarkViewModel.Input(moveBookmark: moveBookmarkRelay.asSignal(), removeBookmark: removeBookmarkRelay.asSignal())
        )
        return (viewModel, baseOutput, output)
    }
}
