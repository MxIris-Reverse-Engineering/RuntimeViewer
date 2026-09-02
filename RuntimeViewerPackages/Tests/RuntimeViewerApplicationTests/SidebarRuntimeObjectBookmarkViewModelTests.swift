import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("SidebarRuntimeObjectBookmarkViewModel")
@MainActor
struct SidebarRuntimeObjectBookmarkViewModelTests {
    private let router = MockRouter<SidebarRuntimeObjectRoute>()
    private let moveBookmarkRelay = PublishRelay<OutlineMove>()
    private let removeBookmarkRelay = PublishRelay<Int>()

    private let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)
    private let nsCopying = Fixtures.runtimeObject(name: "NSCopying", kind: .objc(.type(.protocol)), imagePath: TestImages.libobjc)

    @Test("nodes list the bookmarked objects of this image in stored order")
    func nodesListBookmarkedObjects() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }

        let rows = try await nextValue(from: harness.viewModel.$nodes) { !$0.isEmpty }
        #expect(rows.map(\.runtimeObject) == [nsObject, nsCopying])
        #expect(try await nextValue(from: harness.output.isBookmarkEmpty) == false)
        #expect(try await nextValue(from: harness.baseOutput.loadState) { $0 == .loaded } == .loaded)
    }

    @Test("removing a bookmark drops that row and reports emptiness once the last one goes")
    func removingBookmarkDropsRow() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await nextValue(from: harness.viewModel.$nodes) { $0.count == 2 }

        removeBookmarkRelay.accept(0)
        _ = try await nextValue(from: harness.viewModel.$nodes) { $0.map(\.runtimeObject) == [nsCopying] }

        removeBookmarkRelay.accept(0)
        _ = try await nextValue(from: harness.viewModel.$nodes) { $0.isEmpty }
        #expect(try await nextValue(from: harness.output.isBookmarkEmpty) { $0 } == true)
    }

    @Test("moving a bookmark reorders the stored list")
    func movingBookmarkReorders() async throws {
        let harness = try await makeHarness()
        defer { withExtendedLifetime(harness.viewModel) {} }
        _ = try await nextValue(from: harness.viewModel.$nodes) { $0.count == 2 }

        moveBookmarkRelay.accept(
            OutlineMove(sourceParentPath: nil, sourceIndexes: [0], destinationParentPath: nil, destinationIndex: 2, isDropOnItem: false)
        )

        _ = try await nextValue(from: harness.viewModel.$nodes) { $0.map(\.runtimeObject) == [nsCopying, nsObject] }
        let stored = harness.environment.appDefaults.objectBookmarksByScopeAndImagePath[harness.scopeKey]?[TestImages.libobjc] ?? []
        #expect(stored.map(\.object) == [nsCopying, nsObject])
    }

    // MARK: - Helpers

    private struct Harness {
        let environment: ViewModelTestEnvironment
        let scopeKey: String
        let viewModel: SidebarRuntimeObjectBookmarkViewModel
        let baseOutput: SidebarRuntimeObjectViewModel.Output
        let output: SidebarRuntimeObjectBookmarkViewModel.Output
    }

    private func makeHarness() async throws -> Harness {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let scopeKey = engine.bookmarkScope.bookmarkKey
        environment.appDefaults.objectBookmarksByScopeAndImagePath = [
            scopeKey: [
                TestImages.libobjc: [
                    RuntimeObjectBookmark(object: nsObject),
                    RuntimeObjectBookmark(object: nsCopying),
                ],
            ],
        ]
        let tree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        let leaf = try #require(tree.leaf(forImagePath: TestImages.libobjc))
        let viewModel = environment.make {
            SidebarRuntimeObjectBookmarkViewModel(imageNode: leaf, documentState: environment.documentState, router: router)
        }
        let baseOutput = viewModel.transform(
            SidebarRuntimeObjectViewModel.Input(
                runtimeObjectClicked: .empty(),
                runtimeObjectOpenedInNewTab: .empty(),
                loadImageClicked: .empty(),
                searchString: .just(""),
                isSearchCaseSensitive: .just(false)
            )
        )
        let output = viewModel.transform(
            SidebarRuntimeObjectBookmarkViewModel.Input(moveBookmark: moveBookmarkRelay.asSignal(), removeBookmark: removeBookmarkRelay.asSignal())
        )
        return Harness(environment: environment, scopeKey: scopeKey, viewModel: viewModel, baseOutput: baseOutput, output: output)
    }
}
