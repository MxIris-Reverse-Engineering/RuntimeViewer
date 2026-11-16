import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

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

    /// The rows on screen are the filtered ones, so the row the user removes
    /// is named among them, not by its place in the stored list.
    @Test("removing a bookmark while a filter hides rows removes the row the user picked")
    func removingBookmarkWhileFilteringRemovesPickedRow() async throws {
        try seedBookmarks()
        let (viewModel, _, _) = makeViewModel()
        defer { withExtendedLifetime(viewModel) {} }
        _ = try await nextValue(from: viewModel.$nodes) { $0.count == 2 }

        searchStringRelay.accept("libobjc")
        _ = try await nextValue(from: viewModel.$nodes) { $0.map(\.node.name) == ["libobjc.A.dylib"] }

        // The first row on screen, as the context menu and the Delete key name it.
        removeBookmarkRelay.accept(0)

        let stored = try await nextValue(from: environment.appDefaults.$imageBookmarksByScope) { $0[documentScopeKey]?.count == 1 }
        #expect(stored[documentScopeKey]?.map(\.imageNode.name) == ["Foundation"])
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
            SidebarRootViewModel.Input(clickedNode: .empty(), selectedNode: .empty(), filter: searchStringRelay.asSignal().map { NavigatorTextFilter(typedText: $0) })
        )
        let output = viewModel.transform(
            SidebarRootBookmarkViewModel.Input(moveBookmark: moveBookmarkRelay.asSignal(), removeBookmark: removeBookmarkRelay.asSignal())
        )
        return (viewModel, baseOutput, output)
    }
}
