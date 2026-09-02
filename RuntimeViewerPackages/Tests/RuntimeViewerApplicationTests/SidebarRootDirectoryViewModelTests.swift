import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

@Suite("SidebarRootDirectoryViewModel")
@MainActor
struct SidebarRootDirectoryViewModelTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let addBookmarkRelay = PublishRelay<SidebarRootCellViewModel>()

    @Test("nodes follow the image tree the engine publishes")
    func nodesFollowEngineTree() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let roots = try await nextValue(from: viewModel.$nodes) { !$0.isEmpty }
        #expect(roots.map(\.node.name) == ["Dyld Shared Cache", "Others"])
        #expect(IteratorSequence(roots[0].makeIterator()).contains { $0.isLeaf && $0.node.name == "Foundation" })
    }

    @Test("adding a bookmark stores the image under the engine's bookmark scope")
    func addingBookmarkStoresImage() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let roots = try await nextValue(from: viewModel.$nodes) { !$0.isEmpty }
        let foundationCell = try #require(IteratorSequence(roots[0].makeIterator()).first { $0.isLeaf && $0.node.name == "Foundation" })

        addBookmarkRelay.accept(foundationCell)
        try await settleMainQueue()

        let stored = environment.appDefaults.imageBookmarksByScope[engine.bookmarkScope.bookmarkKey] ?? []
        #expect(stored.map(\.imageNode) == [foundationCell.node])
        #expect(environment.appDefaults.imageBookmarksByScope.count == 1)
    }

    // MARK: - Helpers

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> SidebarRootDirectoryViewModel {
        let viewModel = environment.make {
            SidebarRootDirectoryViewModel(documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(SidebarRootDirectoryViewModel.Input(addBookmark: addBookmarkRelay.asSignal()))
        return viewModel
    }
}
