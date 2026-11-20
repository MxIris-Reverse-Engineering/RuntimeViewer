import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The image list's context menu and the Find results' Copy
/// (proposal `context-menus`).
@Suite("Image and Find result commands")
@MainActor
struct ImageAndFindResultCommandTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let imageActionRelay = PublishRelay<(action: RuntimeImageAction, node: RuntimeImageNode)>()

    @Test("an image offers Open, Find in This Image, Show Naming Word Cloud, Copy Name, Copy Path and Copy Full Path; a folder only the two paths, a grouping root nothing")
    func imageAndFolderCommands() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        let leaf = try #require(tree.leaf(forImagePath: TestImages.libobjc))
        let folder = try #require(leaf.parent)

        // libobjc lives in the dyld shared cache, not on disk: no Show in Finder.
        #expect(viewModel.imageActions(for: leaf) == [.open, .findInImage, .showNamingWordCloud, .copyName, .copyPath, .copyFullPath])
        #expect(viewModel.imageActions(for: folder) == [.copyPath, .copyFullPath])
        #expect(viewModel.imageActions(for: tree).isEmpty)
    }

    @Test("a root that stands for a folder, as a file engine's does, offers Copy Full Path alone")
    func rootStandingForAFolderOffersItsFullPath() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let root = RuntimeImageNode.rootNode(
            for: ["/Copied/Frameworks/Tables.framework/Versions/A/Tables"],
            name: "Frameworks",
            startingAt: "/Copied/Frameworks"
        )

        #expect(viewModel.imageActions(for: root) == [.copyFullPath])
    }

    @Test("Show Naming Word Cloud asks the document's window for the image's word cloud")
    func showNamingWordCloudRequestsTheWindow() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let leaf = try #require(Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc]).leaf(forImagePath: TestImages.libobjc))
        var requestedImagePaths: [String] = []
        let subscription = environment.documentState.namingWordCloudRequested.emitOnNext { requestedImagePaths.append($0) }
        defer { subscription.dispose() }

        imageActionRelay.accept((.showNamingWordCloud, leaf))

        try await waitUntil { requestedImagePaths == [TestImages.libobjc] }
    }

    @Test("an image whose file is on this Mac's disk also offers Show in Finder, which selects the file")
    func imageOnDiskOffersShowInFinder() async throws {
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("RuntimeViewer.ImageCommands.\(UUID().uuidString).dylib")
        try Data().write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let leaf = try #require(Fixtures.imageTree(rootName: "Others", imagePaths: [fileURL.path]).leaf(forImagePath: fileURL.path))

        #expect(viewModel.imageActions(for: leaf).last == .showInFinder)

        imageActionRelay.accept((.showInFinder, leaf))

        #expect(environment.finder.revealedFileURLs == [URL(fileURLWithPath: fileURL.path)])
    }

    @Test("Copy Name copies the image's name, Copy Path the path the list shows, Copy Full Path the whole path; a folder's too")
    func copyNameAndPaths() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        // A node holds its parent weakly: the tree has to outlive the walk up from the leaf.
        let tree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        defer { withExtendedLifetime(tree) {} }
        let leaf = try #require(tree.leaf(forImagePath: TestImages.libobjc))
        let folder = try #require(leaf.parent)
        let shownPath = String(TestImages.libobjc.dropFirst())

        imageActionRelay.accept((.copyName, leaf))
        imageActionRelay.accept((.copyPath, leaf))
        imageActionRelay.accept((.copyFullPath, leaf))
        imageActionRelay.accept((.copyPath, folder))
        imageActionRelay.accept((.copyFullPath, folder))

        let folderFullPath = (TestImages.libobjc as NSString).deletingLastPathComponent
        #expect(environment.pasteboard.copiedStrings == [
            leaf.name, shownPath, TestImages.libobjc,
            String(folderFullPath.dropFirst()), folderFullPath,
        ])
    }

    @Test("the path the list shows leaves out the tree's root; a tree that starts below / gives a path from there; a bookmarked image its name")
    func displayedPathLeavesOutTheRoot() {
        // A node holds its parent weakly: each tree has to outlive the walks up from its leaves.
        let groupedTree = Fixtures.imageTree(rootName: "Dyld Shared Cache", imagePaths: ["/usr/lib/libobjc.A.dylib"])
        defer { withExtendedLifetime(groupedTree) {} }
        let groupedLeaf = groupedTree.leaf(forImagePath: "/usr/lib/libobjc.A.dylib")
        #expect(groupedLeaf?.displayedPath == "usr/lib/libobjc.A.dylib")

        let tablesPath = "/Copied/Frameworks/Tables.framework/Versions/A/Tables"
        let startedRoot = RuntimeImageNode.rootNode(for: [tablesPath], name: "Frameworks", startingAt: "/Copied/Frameworks")
        let startedLeaf = startedRoot.leaf(forImagePath: tablesPath)
        #expect(startedLeaf?.displayedPath == "Tables.framework/Versions/A/Tables")
        #expect(startedLeaf?.fullPath == tablesPath)
        #expect(startedRoot.displayedPath.isEmpty)
        #expect(startedRoot.fullPath == "/Copied/Frameworks")

        let groupingRoot = Fixtures.imageTree(rootName: "Others", imagePaths: [tablesPath])
        #expect(groupingRoot.fullPath == nil)

        let bookmarkedImage = RuntimeImageNode("Tables")
        #expect(bookmarkedImage.displayedPath == "Tables")
    }

    @Test("Find in This Image narrows the Find scope to the image and shows the Find page")
    func findInImageNarrowsTheScope() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        // Made inside the environment, so it records into the environment's defaults.
        let session = environment.make { environment.documentState.findSession }
        let leaf = try #require(Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc]).leaf(forImagePath: TestImages.libobjc))

        imageActionRelay.accept((.findInImage, leaf))

        #expect(session.query.scope == .images([TestImages.libobjc]))
        #expect(router.triggeredRoutes.contains { route in
            if case .find = route { true } else { false }
        })
    }

    @Test("a Find result's Copy copies the text the row shows")
    func findResultCopyCopiesTheRowText() {
        let environment = ViewModelTestEnvironment()
        let copyRelay = PublishRelay<FindResultNode>()
        let viewModel = environment.make {
            FindViewModel<SidebarRootRoute>(documentState: environment.documentState, router: router)
        }
        defer { withExtendedLifetime(viewModel) {} }
        _ = viewModel.transform(.init(
            modePathChoiceSelected: .empty(),
            memberKindFilterSelected: .empty(),
            caseSensitiveToggled: .empty(),
            scopeMenuChoiceSelected: .empty(),
            searchCommitted: .empty(),
            recentQuerySelected: .empty(),
            clearRecentQueriesSelected: .empty(),
            filter: .just(.empty),
            resultClicked: .empty(),
            resultOpenedInNewTab: .empty(),
            resultCollapsed: .empty(),
            resultExpanded: .empty(),
            resultsSelected: .empty(),
            crossReferenceCommandSelected: .empty(),
            runtimeHelperCallsToggled: .empty(),
            resultCopied: copyRelay.asSignal()
        ))
        let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)
        let node = FindResultNode(content: .object(nsObject), identifier: "NSObject")

        copyRelay.accept(node)

        #expect(environment.pasteboard.copiedStrings == [node.filterableText])
    }

    // MARK: - Helpers

    private static func environment() async throws -> ViewModelTestEnvironment {
        ViewModelTestEnvironment(runtimeEngine: try await TestRuntimeEngine.shared())
    }

    private func makeViewModel(in environment: ViewModelTestEnvironment) -> SidebarRootDirectoryViewModel {
        let viewModel = environment.make {
            SidebarRootDirectoryViewModel(documentState: environment.documentState, router: router)
        }
        _ = viewModel.transform(SidebarRootViewModel.Input(clickedNode: .empty(), selectedNode: .empty(), filter: .empty(), imageActionRequested: imageActionRelay.asSignal()))
        return viewModel
    }
}
