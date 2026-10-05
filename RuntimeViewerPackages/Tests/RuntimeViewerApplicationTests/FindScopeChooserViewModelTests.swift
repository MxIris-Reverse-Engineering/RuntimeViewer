import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The scope chooser's contract — the sheet the scope menu's Custom Scopes…
/// opens: it lists the engine's indexed images and the images the scope
/// holds, by name, with the scope's images selected; OK makes the selection
/// the scope and closes the sheet, and so does a double-clicked row; Cancel
/// only closes it; nothing selected, nothing to apply; the filter field
/// narrows the list by name; each row says where its image's corpus stands.
///
/// Every case runs on a private engine: the chooser reads the document's
/// corpus coordinator, which asks its engine for corpora as soon as it exists.
@Suite("FindScopeChooserViewModel", .serialized)
@MainActor
struct FindScopeChooserViewModelTests {
    private let router = MockRouter<SidebarRootRoute>()
    private let filterStringRelay = PublishRelay<String>()
    private let selectionChangedRelay = PublishRelay<Set<String>>()
    private let okClickedRelay = PublishRelay<Void>()
    private let cancelClickedRelay = PublishRelay<Void>()
    private let rowDoubleClickedRelay = PublishRelay<Void>()

    private static let alphaImagePath = "/fixture/Alpha.framework/Alpha"
    private static let zetaImagePath = "/fixture/zeta.dylib"

    @Test("the engine's indexed images and the scope's are listed by name, the scope's selected")
    func listsIndexedAndScopeImages() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.list", loading: [TestImages.libobjc])
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.make { environment.documentState.findSession }.update { $0.scope = .images([Self.zetaImagePath, Self.alphaImagePath]) }
        let (viewModel, output) = makeViewModel(in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let rows = try await nextValue(from: output.rows, timeout: 30) { rows in
            rows.contains { $0.imagePath == TestImages.libobjc }
        }

        #expect(rows.map(\.name) == ["Alpha", "libobjc.A.dylib", "zeta.dylib"])
        #expect(try await nextValue(from: output.selectedImagePaths) == [Self.alphaImagePath, Self.zetaImagePath])
        #expect(try await nextValue(from: output.isOKEnabled) == true)
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

    @Test("OK makes the selection the scope and closes the sheet, without searching")
    func okMakesSelectionTheScope() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.ok")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = makeViewModel(in: environment)
        let session = environment.documentState.findSession
        defer { withExtendedLifetime(viewModel) {} }

        selectionChangedRelay.accept([Self.alphaImagePath, Self.zetaImagePath])
        #expect(try await nextValue(from: output.isOKEnabled) { $0 } == true)
        // Selecting is not applying.
        #expect(session.query.scope == .allIndexedImages)
        #expect(dismissalCount == 0)

        okClickedRelay.accept(())
        #expect(session.query.scope == .images([Self.alphaImagePath, Self.zetaImagePath]))
        #expect(dismissalCount == 1)
        #expect(session.isSearching == false)
        await engine.stop()
    }

    @Test("Cancel closes the sheet and leaves the scope as it was")
    func cancelLeavesScope() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.cancel")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.make { environment.documentState.findSession }.update { $0.scope = .images([Self.alphaImagePath]) }
        let (viewModel, _) = makeViewModel(in: environment)
        let session = environment.documentState.findSession
        defer { withExtendedLifetime(viewModel) {} }

        selectionChangedRelay.accept([Self.zetaImagePath])
        cancelClickedRelay.accept(())

        #expect(session.query.scope == .images([Self.alphaImagePath]))
        #expect(dismissalCount == 1)
        await engine.stop()
    }

    @Test("with nothing selected OK is disabled and applies nothing")
    func emptySelectionAppliesNothing() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.empty")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        environment.make { environment.documentState.findSession }.update { $0.scope = .images([Self.alphaImagePath]) }
        let (viewModel, output) = makeViewModel(in: environment)
        let session = environment.documentState.findSession
        defer { withExtendedLifetime(viewModel) {} }
        #expect(try await nextValue(from: output.isOKEnabled) { $0 } == true)

        selectionChangedRelay.accept([])
        #expect(try await nextValue(from: output.isOKEnabled) { !$0 } == false)
        okClickedRelay.accept(())
        rowDoubleClickedRelay.accept(())

        #expect(session.query.scope == .images([Self.alphaImagePath]))
        #expect(dismissalCount == 0)
        await engine.stop()
    }

    @Test("a double-clicked row is applied as OK applies the selection")
    func doubleClickAppliesSelection() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.doubleClick")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, _) = makeViewModel(in: environment)
        let session = environment.documentState.findSession
        defer { withExtendedLifetime(viewModel) {} }

        // The first click of the two selects the row.
        selectionChangedRelay.accept([Self.zetaImagePath])
        rowDoubleClickedRelay.accept(())

        #expect(session.query.scope == .images([Self.zetaImagePath]))
        #expect(dismissalCount == 1)
        await engine.stop()
    }

    @Test("every indexed image selects nothing; the current image selects the image the sidebar lists")
    func scopesThatPickNoImage() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "FindScopeChooserViewModelTests.current")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let documentState = environment.documentState

        let (allImagesViewModel, allImagesOutput) = makeViewModel(in: environment)
        #expect(try await nextValue(from: allImagesOutput.selectedImagePaths) == [])
        #expect(try await nextValue(from: allImagesOutput.isOKEnabled) == false)
        withExtendedLifetime(allImagesViewModel) {}

        // The tree has to outlive the assertions: a node reaches its path
        // through its parent, which it holds weakly.
        let imageTree = Fixtures.imageTree(rootName: "Images", imagePaths: [TestImages.libobjc])
        documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: TestImages.libobjc))))
        documentState.findSession.update { $0.scope = .currentImage }
        let (currentImageViewModel, currentImageOutput) = makeViewModel(in: environment)
        defer { withExtendedLifetime(currentImageViewModel) {} }

        #expect(try await nextValue(from: currentImageOutput.selectedImagePaths) == [TestImages.libobjc])
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

    /// How many times the chooser asked to be closed.
    private var dismissalCount: Int {
        router.triggeredRoutes.filter { route in
            if case .dismissFindScopeChooser = route { return true }
            return false
        }
        .count
    }

    /// Binds inside the environment's dependencies: `transform` reads the
    /// document's corpus coordinator, which comes into being on first use.
    private func makeViewModel(in environment: ViewModelTestEnvironment) -> (FindScopeChooserViewModel<SidebarRootRoute>, FindScopeChooserViewModel<SidebarRootRoute>.Output) {
        environment.make {
            let viewModel = FindScopeChooserViewModel<SidebarRootRoute>(documentState: environment.documentState, router: router)
            let output = viewModel.transform(.init(
                filterString: filterStringRelay.asDriver(onErrorJustReturn: ""),
                selectionChanged: selectionChangedRelay.asSignal(),
                okClicked: okClickedRelay.asSignal(),
                cancelClicked: cancelClickedRelay.asSignal(),
                rowDoubleClicked: rowDoubleClickedRelay.asSignal()
            ))
            return (viewModel, output)
        }
    }
}
