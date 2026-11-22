#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// While the sidebar's object list is still loading the image the sidebar is in, nothing of that
/// image opens from the other places that list its objects: the image's bookmarks page and the
/// start page's recent objects show the list's loading page instead, and their items come once the
/// list has loaded the image. Both used to list their items at once, so an object could be opened
/// from them in the middle of the indexing.
@Suite("Waiting for the sidebar's object list", .serialized)
@MainActor
struct SidebarImageListLoadWaitTests {
    private let sidebarRouter = MockRouter<SidebarRuntimeObjectRoute>()
    private let contentRouter = MockRouter<ContentRoute>()

    private let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)
    private let nsCopying = Fixtures.runtimeObject(name: "NSCopying", kind: .objc(.type(.protocol)), imagePath: TestImages.libobjc)

    private let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])

    @Test("the image's bookmarks wait for the sidebar's object list while it loads the image")
    func bookmarksWaitForTheList() async throws {
        let environment = try await makeEnvironment()
        environment.appDefaults.objectBookmarksByScopeAndImagePath = [
            environment.documentState.runtimeEngine.bookmarkScope.bookmarkKey: [
                TestImages.libobjc: [RuntimeObjectBookmark(object: nsObject), RuntimeObjectBookmark(object: nsCopying)],
            ],
        ]
        let imageNode = try enterImage(in: environment)
        // As the sidebar makes them: the list first, then the bookmarks.
        let list = environment.make {
            GatedSidebarListViewModel(imageNode: imageNode, documentState: environment.documentState, router: sidebarRouter)
        }
        let bookmarks = environment.make {
            SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, documentState: environment.documentState, router: sidebarRouter)
        }
        defer { withExtendedLifetime((list, bookmarks)) {} }
        try await waitUntil { list.isBuilding }

        let loadStatesWhileTheListLoads = try await values(from: bookmarks.$loadState, during: 0.5)

        #expect(loadStatesWhileTheListLoads.allSatisfy { $0 == .loading })
        #expect(bookmarks.nodes.isEmpty)

        list.finishBuild(with: [nsObject, nsCopying])
        let rows = try await nextValue(from: bookmarks.$nodes) { !$0.isEmpty }
        #expect(rows.map(\.runtimeObject) == [nsObject, nsCopying])
        #expect(bookmarks.loadState == .loaded)
    }

    @Test("the start page's recent objects wait for the sidebar's object list while it loads the image")
    func recentObjectsWaitForTheList() async throws {
        let environment = try await makeEnvironment()
        environment.appDefaults.recentRuntimeImagesByEngine = [
            Settings.Indexing.EngineReference.key(for: environment.documentState.runtimeEngine): [
                RecentRuntimeImage(imagePath: TestImages.libobjc, objects: [nsObject]),
            ],
        ]
        let startPage = makeStartPage(in: environment)
        let imageNode = try enterImage(in: environment)
        let list = environment.make {
            GatedSidebarListViewModel(imageNode: imageNode, documentState: environment.documentState, router: sidebarRouter)
        }
        defer { withExtendedLifetime((startPage, list)) {} }
        try await waitUntil { list.isBuilding }

        let listsWhileTheListLoads = try await values(from: startPage.output.recentItems, during: 0.6)

        #expect(listsWhileTheListLoads.allSatisfy { !Self.containsObject($0) })
        #expect(!Self.containsObject(startPage.viewModel.recentItems))

        list.finishBuild(with: [nsObject])
        let recentObjects = try await nextValue(from: startPage.output.recentItems) { Self.containsObject($0) }
        #expect(recentObjects.map(\.item) == [.object(nsObject)])
    }

    // MARK: - Helpers

    private struct StartPage {
        let viewModel: ContentPlaceholderViewModel
        let output: ContentPlaceholderViewModel.Output
    }

    private func makeEnvironment() async throws -> ViewModelTestEnvironment {
        ViewModelTestEnvironment(runtimeEngine: try await TestRuntimeEngine.shared())
    }

    private func makeStartPage(in environment: ViewModelTestEnvironment) -> StartPage {
        let viewModel = environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: contentRouter)
        }
        return StartPage(viewModel: viewModel, output: viewModel.transform(.init()))
    }

    /// Takes the sidebar of `environment` into libobjc, as the sidebar's image list does.
    private func enterImage(in environment: ViewModelTestEnvironment) throws -> RuntimeImageNode {
        let imageNode = try #require(imageTree.leaf(forImagePath: TestImages.libobjc))
        environment.documentState.selectionRouter.trigger(.switchImage(imageNode))
        return imageNode
    }

    private static func containsObject(_ items: [ContentStartPageItemCellViewModel]) -> Bool {
        items.contains { item in
            guard case .object = item.item else { return false }
            return true
        }
    }
}

#endif
