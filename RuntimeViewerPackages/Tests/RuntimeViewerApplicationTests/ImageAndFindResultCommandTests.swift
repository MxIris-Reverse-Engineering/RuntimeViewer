import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The image list's context menu and the Find results' Copy
/// (draft-context-menus).
@Suite("Image and Find result commands")
@MainActor
struct ImageAndFindResultCommandTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let imageActionRelay = PublishRelay<(action: RuntimeImageAction, node: RuntimeImageNode)>()

    @Test("an image offers Open, Find in This Image, Copy Name and Copy Path, and a folder nothing")
    func imageAndFolderCommands() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let tree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc])
        let leaf = try #require(tree.leaf(forImagePath: TestImages.libobjc))

        // libobjc lives in the dyld shared cache, not on disk: no Show in Finder.
        #expect(viewModel.imageActions(for: leaf) == [.open, .findInImage, .copyName, .copyPath])
        #expect(viewModel.imageActions(for: tree).isEmpty)
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

    @Test("Copy Name and Copy Path copy the image's name and path")
    func copyNameAndPath() async throws {
        let environment = try await Self.environment()
        let viewModel = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        let leaf = try #require(Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc]).leaf(forImagePath: TestImages.libobjc))

        imageActionRelay.accept((.copyName, leaf))
        imageActionRelay.accept((.copyPath, leaf))

        #expect(environment.pasteboard.copiedStrings == [leaf.name, TestImages.libobjc])
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
