#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// File › Open Quickly… (⇧⌘O): the floating bar searches what an empty editor pane's start page
/// searches — the engine's images by name and the objects of its indexed images — as Xcode's
/// Open Quickly window and its initial editor share one search (proposal `editor-start-page`).
///
/// Every test gets an engine of its own with libobjc indexed.
@Suite("Open Quickly bar", .serialized)
@MainActor
struct OpenQuicklyViewModelTests {
    @MainActor
    private struct Bar {
        let environment: ViewModelTestEnvironment
        let router: MockRouter<MainRoute>
        let viewModel: OpenQuicklyViewModel
        let output: OpenQuicklyViewModel.Output
        let searchText: PublishRelay<String>
        let itemOpenings: PublishRelay<ContentStartPageItemOpening>
        let dismissals: PublishRelay<Void>

        var documentState: DocumentState { environment.documentState }

        func matches(for searchText: String) async throws -> OpenQuicklyViewModel.Matches {
            try await nextValue(from: output.matches) { $0.searchText == searchText }
        }
    }

    private func makeBar(engineID: String) async throws -> Bar {
        let engine = try await TestRuntimeEngine.makeConnectedWithItsFirstReloadOver(engineID: engineID)
        try await engine.loadImage(at: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let router = MockRouter<MainRoute>()
        let viewModel = environment.make {
            OpenQuicklyViewModel(documentState: environment.documentState, router: router)
        }
        let searchText = PublishRelay<String>()
        let itemOpenings = PublishRelay<ContentStartPageItemOpening>()
        let dismissals = PublishRelay<Void>()
        let output = viewModel.transform(.init(
            searchText: searchText.asSignal(),
            itemOpened: itemOpenings.asSignal(),
            dismissed: dismissals.asSignal()
        ))
        return Bar(
            environment: environment,
            router: router,
            viewModel: viewModel,
            output: output,
            searchText: searchText,
            itemOpenings: itemOpenings,
            dismissals: dismissals
        )
    }

    @Test("a term lists the engine's images by name and the objects of its indexed images")
    func termListsImagesAndIndexedObjects() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.scope")
        let engine = bar.documentState.runtimeEngine
        let indexedBefore = Set(try await engine.indexedImagePathList())

        bar.searchText.accept("NSObject")
        let objectMatches = try await bar.matches(for: "NSObject")
        bar.searchText.accept("libobjc")
        let imageMatches = try await bar.matches(for: "libobjc")

        #expect(objectMatches.items.contains { row in
            if case .object(let object) = row.item { return object.displayName == "NSObject" }
            return false
        })
        #expect(imageMatches.items.contains { row in
            if case .image(let path) = row.item { return path.hasSuffix("libobjc.A.dylib") }
            return false
        })
        let objectImagePaths = Set(objectMatches.items.compactMap { row -> String? in
            guard case .object(let object) = row.item else { return nil }
            return object.imagePath
        })
        #expect(objectImagePaths.isSubset(of: indexedBefore))
        #expect(Set(try await engine.indexedImagePathList()) == indexedBefore)
    }

    @Test("a single character searches")
    func singleCharacterSearches() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.single")

        bar.searchText.accept("N")

        #expect(try await !bar.matches(for: "N").items.isEmpty)
    }

    @Test("an empty term lists nothing")
    func emptyTermListsNothing() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.empty")
        var answers: [OpenQuicklyViewModel.Matches] = []
        let disposeBag = DisposeBag()
        bar.output.matches.emitOnNext { answers.append($0) }.disposed(by: disposeBag)

        bar.searchText.accept("")

        // An empty term is answered at once, without reading anything.
        #expect(answers == [OpenQuicklyViewModel.Matches(searchText: "", items: [])])
    }

    @Test("only the newest term's matches come out when terms follow each other")
    func onlyTheNewestTermsMatchesComeOut() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.newest")
        var answeredTerms: [String] = []
        let disposeBag = DisposeBag()
        bar.output.matches.emitOnNext { answeredTerms.append($0.searchText) }.disposed(by: disposeBag)

        bar.searchText.accept("NSObj")
        bar.searchText.accept("libobjc")

        _ = try await bar.matches(for: "libobjc")
        #expect(answeredTerms == ["libobjc"])
    }

    @Test("closing the bar drops the search still under way")
    func closingDropsTheSearchUnderWay() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.closeMidSearch")
        var answeredTerms: [String] = []
        let disposeBag = DisposeBag()
        bar.output.matches.emitOnNext { answeredTerms.append($0.searchText) }.disposed(by: disposeBag)

        bar.searchText.accept("NSObject")
        bar.dismissals.accept(())

        // Reading libobjc's catalog and matching it takes far less than this.
        _ = try await values(from: bar.output.matches, during: 1)
        #expect(answeredTerms.isEmpty)
    }

    @Test("a window moved to another engine drops the search under way")
    func engineSwitchDropsTheSearchUnderWay() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.switchMidSearch")
        var answeredTerms: [String] = []
        let disposeBag = DisposeBag()
        bar.output.matches.emitOnNext { answeredTerms.append($0.searchText) }.disposed(by: disposeBag)

        bar.searchText.accept("NSObject")
        bar.documentState.selectionRouter.trigger(.switchEngine(TestRuntimeEngine.makeUnreachable()))

        _ = try await values(from: bar.output.matches, during: 1)
        #expect(answeredTerms.isEmpty)
    }

    @Test("opening an object shows it in the focused pane's tab")
    func openingAnObjectShowsIt() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.openObject")
        bar.searchText.accept("NSObject")
        let row = try #require(try await bar.matches(for: "NSObject").items.first { row in
            if case .object(let object) = row.item { return object.displayName == "NSObject" }
            return false
        })

        bar.itemOpenings.accept(.init(item: row, destination: .focusedTab))

        #expect(bar.documentState.selectedRuntimeObject?.displayName == "NSObject")
    }

    @Test("opening an image shows its image page")
    func openingAnImageShowsItsPage() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.openImage")
        bar.searchText.accept("libobjc")
        let row = try #require(try await bar.matches(for: "libobjc").items.first { row in
            if case .image = row.item { return true }
            return false
        })
        guard case .image(let imagePath) = row.item else { return }

        bar.itemOpenings.accept(.init(item: row, destination: .focusedTab))

        #expect(bar.documentState.editorArea.focusedPane.activeTab.imagePath == imagePath)
    }

    @Test("an object a tab shows already opens in that tab's form")
    func objectShownInATabOpensInThatForm() async throws {
        let bar = try await makeBar(engineID: "OpenQuicklyViewModelTests.form")
        bar.searchText.accept("NSObject")
        let row = try #require(try await bar.matches(for: "NSObject").items.first { row in
            if case .object(let object) = row.item { return object.displayName == "NSObject" }
            return false
        })
        guard case .object(let object) = row.item else { return }
        let shownForm = object.withChildren(object.children + [Fixtures.runtimeObject(name: "Shown", imagePath: object.imagePath)])
        bar.documentState.selectionRouter.trigger(.open(shownForm, in: .focusedTab))
        bar.documentState.selectionRouter.trigger(.newTab)

        bar.itemOpenings.accept(.init(item: row, destination: .focusedTab))

        #expect(bar.documentState.selectedRuntimeObject?.children.count == shownForm.children.count)
    }
}

#endif
