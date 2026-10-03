import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The scope chooser's contract: it lists the engine's indexed images and the
/// images already picked, by name; a checkbox picks or drops an image; the two
/// scopes that pick no image are a click away; the filter field narrows the
/// list by name; each row says where its image's corpus stands.
///
/// Every case runs on a private engine: the chooser reads the document's
/// corpus coordinator, which asks its engine for corpora as soon as it exists.
@Suite("FindScopeChooserViewModel", .serialized)
@MainActor
struct FindScopeChooserViewModelTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let filterStringRelay = PublishRelay<String>()
    private let allIndexedImagesClickedRelay = PublishRelay<Void>()
    private let currentImageClickedRelay = PublishRelay<Void>()
    private let imageToggledRelay = PublishRelay<String>()

    private static let alphaImagePath = "/fixture/Alpha.framework/Alpha"
    private static let zetaImagePath = "/fixture/zeta.dylib"

    @Test("the engine's indexed images and the picked ones are listed by name")
    func listsIndexedAndPickedImages() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.list", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.make { environment.documentState.findSession }.update { $0.scope = .images([Self.zetaImagePath, Self.alphaImagePath]) }
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await nextValue(from: output.rows, timeout: 30) { rows in
            rows.contains { $0.imagePath == TestImages.libobjc }
        }

        #expect(rows.map(\.name) == ["Alpha", "libobjc.A.dylib", "zeta.dylib"])
        #expect(rows.map(\.isPicked) == [true, false, true])
        await engine.stop()
    }

    @Test("a picked image the engine has not indexed says so")
    func pickedImageNotIndexed() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.notIndexed", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.make { environment.documentState.findSession }.update { $0.scope = .images([Self.alphaImagePath]) }
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        // Said once the engine has listed what it indexed, and not before.
        let rows = try await nextValue(from: output.rows, timeout: 30) { rows in
            rows.contains { $0.imagePath == Self.alphaImagePath && $0.status == "not indexed" }
        }

        #expect(rows.first { $0.imagePath == TestImages.libobjc }?.status != "not indexed")
        await engine.stop()
    }

    @Test("a checkbox picks an image, a second click drops it, and dropping the last goes back to every image")
    func checkboxesPickAndDrop() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.toggle")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, _) = makeViewModel(in: environment)
        let session = environment.documentState.findSession
        defer { withExtendedLifetime(viewModel) {} }

        imageToggledRelay.accept(Self.alphaImagePath)
        #expect(session.query.scope == .images([Self.alphaImagePath]))
        imageToggledRelay.accept(Self.zetaImagePath)
        #expect(session.query.scope == .images([Self.alphaImagePath, Self.zetaImagePath]))
        imageToggledRelay.accept(Self.alphaImagePath)
        #expect(session.query.scope == .images([Self.zetaImagePath]))
        imageToggledRelay.accept(Self.zetaImagePath)
        #expect(session.query.scope == .allIndexedImages)
        // Picking an image is an edit of the query, not a search.
        #expect(session.isSearching == false)
        await engine.stop()
    }

    @Test("the current image can be the scope only while the sidebar lists one, and every image is a click away")
    func scopesThatPickNoImage() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.current")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let documentState = environment.documentState
        let (viewModel, output) = makeViewModel(in: environment)
        let session = documentState.findSession
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.isCurrentImageAvailable) == false)
        #expect(try await nextValue(from: output.currentImageTitle) == "Current Image")
        currentImageClickedRelay.accept(())
        #expect(session.query.scope == .allIndexedImages)

        // The tree has to outlive the assertions: a node reaches its path
        // through its parent, which it holds weakly.
        let imageTree = Fixtures.imageTree(rootName: "Images", imagePaths: [TestImages.libobjc])
        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: TestImages.libobjc))))
        #expect(try await nextValue(from: output.isCurrentImageAvailable) { $0 } == true)
        #expect(try await nextValue(from: output.currentImageTitle) { $0 != "Current Image" } == "Current Image (libobjc.A.dylib)")
        currentImageClickedRelay.accept(())
        #expect(session.query.scope == .currentImage)

        allIndexedImagesClickedRelay.accept(())
        #expect(session.query.scope == .allIndexedImages)
        withExtendedLifetime(imageTree) {}
        await engine.stop()
    }

    @Test("the filter field narrows the rows to the image names containing it")
    func filterNarrowsRows() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.filter")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.make { environment.documentState.findSession }.update { $0.scope = .images([Self.alphaImagePath, Self.zetaImagePath]) }
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }
        #expect(try await nextValue(from: output.rows) { $0.count == 2 }.count == 2)

        filterStringRelay.accept("ALP")
        #expect(try await nextValue(from: output.rows) { $0.count == 1 }.map(\.name) == ["Alpha"])

        filterStringRelay.accept("")
        #expect(try await nextValue(from: output.rows) { $0.count == 2 }.count == 2)
        await engine.stop()
    }

    @Test("a row says where its image's corpus stands", arguments: [
        (RuntimeInterfaceCorpusBuildState?.some(.pending), true, "waiting"),
        (.some(.building(RuntimeInterfaceCorpusBuildProgress(built: 37, total: 100))), true, "building 37%"),
        (.some(.failed(message: "boom")), true, "failed"),
        (.some(.built(RuntimeInterfaceCorpusBuildSummary(objectCount: 1, skippedCount: 0, byteCount: 1))), true, ""),
        (nil, true, ""),
        (nil, false, "not indexed"),
    ])
    func corpusStatus(buildState: RuntimeInterfaceCorpusBuildState?, isIndexed: Bool, expectedStatus: String) {
        #expect(FindScopeChooserViewModel<SidebarRootRoute>.status(of: buildState, isIndexed: isIndexed) == expectedStatus)
    }

    // MARK: - Helpers

    /// Binds inside the environment's dependencies: `transform` reads the
    /// document's corpus coordinator, which comes into being on first use.
    private func makeViewModel(in environment: ViewModelTestEnvironment) -> (FindScopeChooserViewModel<SidebarRootRoute>, FindScopeChooserViewModel<SidebarRootRoute>.Output) {
        environment.make {
            let viewModel = FindScopeChooserViewModel<SidebarRootRoute>(documentState: environment.documentState, router: router)
            let output = viewModel.transform(.init(
                filterString: filterStringRelay.asDriver(onErrorJustReturn: ""),
                allIndexedImagesClicked: allIndexedImagesClickedRelay.asSignal(),
                currentImageClicked: currentImageClickedRelay.asSignal(),
                imageToggled: imageToggledRelay.asSignal()
            ))
            return (viewModel, output)
        }
    }
}
