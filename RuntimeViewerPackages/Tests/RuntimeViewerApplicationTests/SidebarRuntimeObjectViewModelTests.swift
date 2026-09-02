import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// The base class produces no objects of its own (`buildRuntimeObjects` is
/// empty), which makes it the right subject for the load-state machine and
/// the pure `makeSections` helper. Real object lists are covered by
/// `SidebarRuntimeObjectListViewModelTests`.
@Suite("SidebarRuntimeObjectViewModel")
@MainActor
struct SidebarRuntimeObjectViewModelTests {
    private let router = MockRouter<SidebarRuntimeObjectRoute>()
    private let loadImageRelay = PublishRelay<Void>()

    // MARK: - makeSections

    @Test("makeSections groups by kind, orders sections by kind and keeps encounter order inside a section")
    func makeSectionsGroupsAndOrders() {
        let environment = ViewModelTestEnvironment()
        let cells = environment.make {
            [
                Fixtures.runtimeObject(name: "SwiftA", kind: .swift(.type(.class))),
                Fixtures.runtimeObject(name: "ObjCX", kind: .objc(.type(.class))),
                Fixtures.runtimeObject(name: "SwiftB", kind: .swift(.type(.class))),
                Fixtures.runtimeObject(name: "ObjCP", kind: .objc(.type(.protocol))),
            ]
            .map { SidebarRuntimeObjectCellViewModel(runtimeObject: $0, forOpenQuickly: false) }
        }

        let sections = SidebarRuntimeObjectViewModel.makeSections(from: cells)

        #expect(sections.map(\.kind) == [.objc(.type(.class)), .objc(.type(.protocol)), .swift(.type(.class))])
        #expect(sections.map { $0.objects.map(\.runtimeObject.name) } == [["ObjCX"], ["ObjCP"], ["SwiftA", "SwiftB"]])
        #expect(sections.map(\.title) == ["Objective-C Class", "Objective-C Protocol", "Swift Class"])
    }

    @Test("makeSections of nothing is nothing")
    func makeSectionsOfNothing() {
        #expect(SidebarRuntimeObjectViewModel.makeSections(from: []).isEmpty)
    }

    // MARK: - Load state

    @Test("an image the engine has loaded that yields no objects reports loaded and empty")
    func loadedImageWithoutObjects() async throws {
        let engine = try await TestRuntimeEngine.shared()
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = try makeViewModel(imagePath: TestImages.libobjc, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.loadState) { $0 == .loaded } == .loaded)
        #expect(try await nextValue(from: output.isEmpty) == true)
        #expect(try await nextValue(from: output.emptyText) == "libobjc.A.dylib is loaded however does not appear to contain any classes or protocols")
    }

    @Test("an image the process has not loaded reports notLoaded until the user asks to load it")
    func unloadedImageLoadsOnRequest() async throws {
        let engine = try await TestRuntimeEngine.makeConnected(engineID: "RuntimeViewerApplicationTests.unloaded-image")
        let candidate = try await unloadedImage(in: engine)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let (viewModel, output) = try makeViewModel(imageNode: candidate, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        #expect(try await nextValue(from: output.loadState) { $0 == .notLoaded } == .notLoaded)
        #expect(try await nextValue(from: output.notLoadedText) == "\(candidate.name) is not yet loaded")

        loadImageRelay.accept(())

        #expect(try await nextValue(from: output.loadState, timeout: 60) { $0 == .loaded } == .loaded)
        #expect(try await engine.isImageLoaded(path: candidate.path))
    }

    @Test("an engine that cannot answer surfaces a load error with the image path")
    func unreachableEngineSurfacesError() async throws {
        let environment = ViewModelTestEnvironment(runtimeEngine: TestRuntimeEngine.makeUnreachable())
        let (viewModel, output) = try makeViewModel(imagePath: TestImages.libobjc, in: environment)
        defer { withExtendedLifetime(viewModel) {} }

        let failedState = try await nextValue(from: output.loadState) { state in
            if case .loadError = state { return true }
            return false
        }
        guard case .loadError = failedState else {
            Issue.record("expected loadError, got \(failedState)")
            return
        }
        let errorText = try await nextValue(from: output.errorText)
        #expect(errorText.hasPrefix("An unknown error"))
        #expect(errorText.contains(TestImages.libobjc))
    }

    // MARK: - Helpers

    private func makeViewModel(
        imagePath: String,
        in environment: ViewModelTestEnvironment
    ) throws -> (SidebarRuntimeObjectViewModel, SidebarRuntimeObjectViewModel.Output) {
        let tree = Fixtures.imageTree(rootName: "Root", imagePaths: [imagePath])
        let leaf = try #require(tree.leaf(forImagePath: imagePath))
        return try makeViewModel(imageNode: leaf, in: environment)
    }

    private func makeViewModel(
        imageNode: RuntimeImageNode,
        in environment: ViewModelTestEnvironment
    ) throws -> (SidebarRuntimeObjectViewModel, SidebarRuntimeObjectViewModel.Output) {
        let viewModel = environment.make {
            SidebarRuntimeObjectViewModel(imageNode: imageNode, documentState: environment.documentState, router: router)
        }
        let output = viewModel.transform(
            .init(
                runtimeObjectClicked: .empty(),
                runtimeObjectOpenedInNewTab: .empty(),
                loadImageClicked: loadImageRelay.asSignal(),
                searchString: .just(""),
                isSearchCaseSensitive: .just(false)
            )
        )
        return (viewModel, output)
    }

    /// A shared-cache framework this process has not mapped yet. Loading it
    /// is process-wide, so only this suite may use these candidates.
    private func unloadedImage(in engine: RuntimeEngine) async throws -> RuntimeImageNode {
        let candidateNames = ["CoreMIDI", "ExternalAccessory", "Collaboration", "GameController", "MediaAccessibility"]
        for candidateName in candidateNames {
            guard let leaf = engine.imageNodes.lazy.compactMap({ $0.leaf(named: candidateName) }).first else { continue }
            if try await engine.isImageLoaded(path: leaf.path) == false {
                return leaf
            }
        }
        throw NoUnloadedCandidateImage(candidateNames: candidateNames)
    }
}

private struct NoUnloadedCandidateImage: Error, CustomStringConvertible {
    let candidateNames: [String]

    var description: String { "every candidate image is already loaded in this process: \(candidateNames)" }
}
