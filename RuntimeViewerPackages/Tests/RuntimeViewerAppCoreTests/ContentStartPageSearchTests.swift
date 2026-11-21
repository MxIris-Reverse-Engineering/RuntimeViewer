#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The Open Quickly field of an empty editor pane's start page (proposal `editor-start-page`): it
/// searches the engine's images by name and the objects of its indexed images once three
/// characters are typed, as Xcode's initial editor does, and opens what Return or a click chooses.
///
/// Every test gets an engine of its own with libobjc indexed, so libobjc's objects are searchable
/// and Foundation's — loaded in the test process, never indexed by this engine — are not.
@Suite("Start page Open Quickly", .serialized)
@MainActor
struct ContentStartPageSearchTests {
    @MainActor
    private struct StartPage {
        let environment: ViewModelTestEnvironment
        let router: MockRouter<ContentRoute>
        let viewModel: ContentPlaceholderViewModel
        let output: ContentPlaceholderViewModel.Output
        let searchText: PublishRelay<String>
        let selectionMoves: PublishRelay<Int>
        let commits: PublishRelay<SelectionRoute.Destination>
        let resultOpenings: PublishRelay<ContentStartPageItemOpening>
        let cancellations: PublishRelay<Void>
        let clearedFieldCount: Box<Int>
        let disposeBag = DisposeBag()

        var documentState: DocumentState { environment.documentState }

        /// The search once it has results, waiting for them.
        func results() async throws -> (rows: [ContentStartPageItemCellViewModel], selectedIndex: Int?) {
            let search = try await nextValue(from: output.search) { search in
                if case .results = search { return true }
                return false
            }
            guard case .results(let rows, let selectedIndex) = search else { throw SequenceCompletedWithoutValue() }
            return (rows, selectedIndex)
        }
    }

    final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeStartPage(engineID: String) async throws -> StartPage {
        let engine = try await TestRuntimeEngine.makeConnectedWithItsFirstReloadOver(engineID: engineID)
        try await engine.loadImage(at: TestImages.libobjc)
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let router = MockRouter<ContentRoute>()
        let viewModel = environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: router, editorPaneID: environment.documentState.editorArea.focusedPaneID)
        }
        let searchText = PublishRelay<String>()
        let selectionMoves = PublishRelay<Int>()
        let commits = PublishRelay<SelectionRoute.Destination>()
        let resultOpenings = PublishRelay<ContentStartPageItemOpening>()
        let cancellations = PublishRelay<Void>()
        let output = viewModel.transform(.init(
            searchText: searchText.asSignal(),
            searchSelectionMoved: selectionMoves.asSignal(),
            searchCommitted: commits.asSignal(),
            searchResultOpened: resultOpenings.asSignal(),
            searchCancelled: cancellations.asSignal()
        ))
        let startPage = StartPage(
            environment: environment,
            router: router,
            viewModel: viewModel,
            output: output,
            searchText: searchText,
            selectionMoves: selectionMoves,
            commits: commits,
            resultOpenings: resultOpenings,
            cancellations: cancellations,
            clearedFieldCount: Box(0)
        )
        output.clearSearchField.emitOnNext { [clearedFieldCount = startPage.clearedFieldCount] in
            clearedFieldCount.value += 1
        }
        .disposed(by: startPage.disposeBag)
        return startPage
    }

    @Test("fewer than three characters search nothing")
    func fewerThanThreeCharactersSearchNothing() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.short")

        startPage.searchText.accept("NS")

        // A search started anyway would land well within this time: the catalog is libobjc's.
        let searchesWhileShort = try await values(from: startPage.output.search, during: 0.5)
        #expect(searchesWhileShort.allSatisfy { $0 == .inactive })
        startPage.searchText.accept("NSO")
        _ = try await startPage.results()
    }

    @Test("an image is found by its file name")
    func imageIsFoundByName() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.image")

        startPage.searchText.accept("libobjc")

        let results = try await startPage.results()
        #expect(results.rows.contains { row in
            if case .image(let path) = row.item { return path.hasSuffix("libobjc.A.dylib") }
            return false
        })
        #expect(results.selectedIndex == 0)
    }

    @Test("objects come from indexed images only, and searching indexes nothing")
    func indexedObjectsOnly() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.objects")
        let engine = startPage.documentState.runtimeEngine
        let indexedBefore = Set(try await engine.indexedImagePathList())

        startPage.searchText.accept("NSObject")

        let results = try await startPage.results()
        let objectImagePaths = Set(results.rows.compactMap { row -> String? in
            guard case .object(let object) = row.item else { return nil }
            return object.imagePath
        })
        #expect(objectImagePaths.contains(engine.canonicalImagePath(TestImages.libobjc)))
        #expect(objectImagePaths.isSubset(of: indexedBefore))
        #expect(Set(try await engine.indexedImagePathList()) == indexedBefore)
    }

    @Test("text cut below three characters mid-search lets that search finish")
    func shortTextMidSearchLetsTheSearchFinish() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.shortMidSearch")

        startPage.searchText.accept("NSObject")
        startPage.searchText.accept("NS")

        let results = try await startPage.results()
        #expect(results.rows.contains { $0.appearance.title == "NSObject" })
    }

    @Test("a window moved to another engine ends the search")
    func engineSwitchEndsTheSearch() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.engineSwitch")
        startPage.searchText.accept("NSObject")
        _ = try await startPage.results()

        startPage.documentState.selectionRouter.trigger(.switchEngine(TestRuntimeEngine.makeUnreachable()))

        _ = try await nextValue(from: startPage.output.search) { $0 == .inactive }
        #expect(startPage.clearedFieldCount.value >= 1)
    }

    @Test("Return opens the selected result, the first unless moved")
    func returnOpensTheSelectedResult() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.return")
        startPage.searchText.accept("NSObject")
        let results = try await startPage.results()
        try #require(results.rows.count >= 2)

        startPage.selectionMoves.accept(1)
        #expect(try await startPage.results().selectedIndex == 1)
        startPage.selectionMoves.accept(-1)
        startPage.selectionMoves.accept(-1)
        #expect(try await startPage.results().selectedIndex == 0)

        startPage.commits.accept(.focusedTab)

        let focusedTab = startPage.documentState.editorArea.focusedPane.activeTab
        switch results.rows[0].item {
        case .object(let object):
            #expect(focusedTab.object == object)
        case .image(let path):
            #expect(focusedTab.imagePath == path)
        }
    }

    @Test("choosing an image opens its image page")
    func choosingAnImageOpensItsImagePage() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.imagePage")
        startPage.searchText.accept("libobjc")
        let results = try await startPage.results()
        let imageRow = try #require(results.rows.first { row in
            if case .image = row.item { return true }
            return false
        })
        guard case .image(let imagePath) = imageRow.item else { return }

        startPage.resultOpenings.accept(.init(item: imageRow, destination: .focusedTab))

        #expect(startPage.documentState.editorArea.focusedPane.activeTab.imagePath == imagePath)
    }

    @Test("opening a result clears the search and the field")
    func openingClearsTheSearch() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.clearOnOpen")
        startPage.searchText.accept("NSObject")
        _ = try await startPage.results()

        startPage.commits.accept(.focusedTab)

        #expect(startPage.viewModel.search == .inactive)
        #expect(startPage.clearedFieldCount.value == 1)
    }

    @Test("Escape clears the search and the field")
    func escapeClearsTheSearch() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.escape")
        startPage.searchText.accept("NSObject")
        _ = try await startPage.results()

        startPage.cancellations.accept(())

        #expect(startPage.viewModel.search == .inactive)
        #expect(startPage.clearedFieldCount.value == 1)
        #expect(startPage.documentState.selectedRuntimeObject == nil)
    }

    @Test("emptying the field clears the results, and fewer than three characters keep them")
    func emptyingClearsAndShortTextKeeps() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.keep")
        startPage.searchText.accept("NSObject")
        let results = try await startPage.results()

        startPage.searchText.accept("NS")
        let searchesWhileShort = try await values(from: startPage.output.search, during: 0.5)
        #expect(searchesWhileShort.allSatisfy { $0 == .results(results.rows, selectedIndex: results.selectedIndex) })

        startPage.searchText.accept("")
        #expect(startPage.viewModel.search == .inactive)
    }

    @Test("Return before the newest text's results arrive opens the newest first result, not an older one")
    func returnWaitsForTheNewestResults() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.returnWaits")
        startPage.searchText.accept("libobjc")
        let olderResults = try await startPage.results()
        guard case .image = olderResults.rows.first?.item else {
            Issue.record("the older search's first result is no image: \(olderResults.rows.first?.appearance.title ?? "none")")
            return
        }

        startPage.searchText.accept("NSObject")
        startPage.commits.accept(.focusedTab)

        try await waitUntil { startPage.documentState.selectedRuntimeObject != nil || startPage.documentState.editorArea.focusedPane.activeTab.imagePath != nil }
        #expect(startPage.documentState.editorArea.focusedPane.activeTab.imagePath == nil)
        #expect(startPage.documentState.selectedRuntimeObject?.displayName == "NSObject")
    }

    @Test("Return while the first search is still reading opens its first result once it arrives")
    func returnDuringTheFirstSearchIsKept() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.returnDuringFirst")

        startPage.searchText.accept("NSObject")
        startPage.commits.accept(.focusedTab)

        try await waitUntil { startPage.documentState.selectedRuntimeObject != nil }
        #expect(startPage.documentState.selectedRuntimeObject?.displayName == "NSObject")
        // The held Return opens from inside the results' delivery, so the end of the search it
        // starts is delivered one main-queue turn after the object opens.
        try await waitUntil { startPage.viewModel.search == .inactive }
    }

    @Test("Return waiting for its results is dropped once the text changes again")
    func waitingReturnIsDroppedWhenTheTextChanges() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.returnDropped")

        startPage.searchText.accept("NSObject")
        startPage.commits.accept(.focusedTab)
        startPage.searchText.accept("NSObj")

        _ = try await nextValue(from: startPage.output.search) { search in
            if case .results = search { return true }
            return false
        }
        #expect(startPage.documentState.selectedRuntimeObject == nil)
        #expect(startPage.documentState.editorArea.focusedPane.activeTab.imagePath == nil)
    }

    @Test("Return with nothing found opens nothing")
    func returnWithNothingFoundOpensNothing() async throws {
        let startPage = try await makeStartPage(engineID: "ContentStartPageSearchTests.nothing")
        startPage.searchText.accept("ZZZQQQXXXNothingByThisName")
        let results = try await startPage.results()
        #expect(results.rows.isEmpty)
        #expect(results.selectedIndex == nil)

        startPage.commits.accept(.focusedTab)

        #expect(startPage.documentState.selectedRuntimeObject == nil)
    }
}

#endif
