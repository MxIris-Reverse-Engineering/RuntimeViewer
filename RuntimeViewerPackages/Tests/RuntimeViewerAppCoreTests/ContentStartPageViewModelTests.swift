#if os(macOS)

import Foundation
import Testing
import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
import RuntimeViewerSettings

/// The start page an empty editor pane shows (proposal `editor-start-page`), driven through
/// `ContentPlaceholderViewModel`: the engine's recent objects.
@Suite("Start page", .serialized)
@MainActor
struct ContentStartPageViewModelTests {
    /// A start page under test. The view model holds its router `unowned`, so the page keeps both.
    private struct StartPage {
        let router: MockRouter<ContentRoute>
        let viewModel: ContentPlaceholderViewModel
        let output: ContentPlaceholderViewModel.Output
        let showAllClicks: PublishRelay<Void>
        let recentItemOpenings: PublishRelay<ContentPlaceholderViewModel.ItemOpening>
        let pageAppearances: PublishRelay<Void>
    }

    private func makeStartPage(in environment: ViewModelTestEnvironment, editorPaneID: EditorPane.ID? = nil) -> StartPage {
        let router = MockRouter<ContentRoute>()
        let viewModel = environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: router, editorPaneID: editorPaneID)
        }
        let showAllClicks = PublishRelay<Void>()
        let recentItemOpenings = PublishRelay<ContentPlaceholderViewModel.ItemOpening>()
        let pageAppearances = PublishRelay<Void>()
        let output = viewModel.transform(.init(
            pageWillAppear: pageAppearances.asSignal(),
            showAllClicked: showAllClicks.asSignal(),
            recentItemOpened: recentItemOpenings.asSignal()
        ))
        return StartPage(router: router, viewModel: viewModel, output: output, showAllClicks: showAllClicks, recentItemOpenings: recentItemOpenings, pageAppearances: pageAppearances)
    }

    private func recentObjects(count: Int) -> [RuntimeObject] {
        (0 ..< count).map { Fixtures.runtimeObject(name: "Recent\($0)") }
    }

    private func engineKey(of environment: ViewModelTestEnvironment) -> String {
        Settings.Indexing.EngineReference.key(for: environment.documentState.runtimeEngine)
    }

    @Test("the start page lists the engine's recent objects, most recent first")
    func listsTheEnginesRecentObjects() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [
            engineKey(of: environment): [Fixtures.runtimeObject(name: "Second"), Fixtures.runtimeObject(name: "First")],
        ]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let output = startPage.output

        let recentItems = try await nextValue(from: output.recentItems) { !$0.isEmpty }

        #expect(recentItems.map(\.appearance.title) == ["Second", "First"])
        #expect(recentItems.first?.appearance.pathComponents == [environment.documentState.runtimeEngine.source.description, "Sample"])
    }

    @Test("an object recorded by another window on the engine shows up")
    func objectRecordedElsewhereShowsUp() async throws {
        let environment = ViewModelTestEnvironment()
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let output = startPage.output

        environment.appDefaults.recentRuntimeObjectsByEngine = [
            engineKey(of: environment): [Fixtures.runtimeObject(name: "Recorded")],
        ]

        let recentItems = try await nextValue(from: output.recentItems) { !$0.isEmpty }
        #expect(recentItems.map(\.appearance.title) == ["Recorded"])
    }

    @Test("another engine's recent objects are not listed")
    func anotherEnginesRecentObjectsAreNotListed() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [
            "scope:another-engine": [Fixtures.runtimeObject(name: "Elsewhere")],
            engineKey(of: environment): [Fixtures.runtimeObject(name: "Here")],
        ]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }
        #expect(recentItems.map(\.appearance.title) == ["Here"])
    }

    @Test("a record on another engine leaves the list as it is")
    func recordOnAnotherEngineLeavesTheList() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): [Fixtures.runtimeObject(name: "Here")]]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let listed = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }

        environment.appDefaults.recentRuntimeObjectsByEngine["scope:another-engine"] = [Fixtures.runtimeObject(name: "Elsewhere")]
        environment.appDefaults.recentRuntimeObjectsByEngine[engineKey(of: environment)] = [Fixtures.runtimeObject(name: "Next"), Fixtures.runtimeObject(name: "Here")]

        let relisted = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "Next" }
        #expect(relisted.map(\.appearance.title) == ["Next", "Here"])
        #expect(listed.map(\.appearance.title) == ["Here"])
    }

    @Test("a window moved to another engine lists that engine's recent objects")
    func windowMovedToAnotherEngineListsItsObjects() async throws {
        let environment = ViewModelTestEnvironment()
        let otherEngine = TestRuntimeEngine.makeUnreachable()
        let otherEngineKey = Settings.Indexing.EngineReference.key(for: otherEngine)
        environment.appDefaults.recentRuntimeObjectsByEngine = [
            engineKey(of: environment): [Fixtures.runtimeObject(name: "OnFirstEngine")],
            otherEngineKey: [Fixtures.runtimeObject(name: "OnOtherEngine")],
        ]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "OnFirstEngine" }

        environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine))

        let recentItems = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "OnOtherEngine" }
        #expect(recentItems.map(\.appearance.title) == ["OnOtherEngine"])
    }

    // MARK: - Show All

    @Test("more recent objects than the default row count show the first eight and Show All")
    func moreThanEightShowEightAndShowAll() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): recentObjects(count: 10)]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }
        #expect(ContentPlaceholderViewModel.defaultRecentRowCount == 8)
        #expect(recentItems.map(\.appearance.title) == (0 ..< 8).map { "Recent\($0)" })
        #expect(try await nextValue(from: startPage.output.showAllButton) == .showAll)
        #expect(ContentPlaceholderViewModel.ShowAllButton.showAll.title == "Show All")
    }

    @Test("no more recent objects than the default row count show them all with no button")
    func eightOrFewerShowNoButton() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): recentObjects(count: 8)]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }
        #expect(recentItems.count == 8)
        #expect(try await nextValue(from: startPage.output.showAllButton) == .hidden)
    }

    @Test("Show All shows every recent object and becomes Show Less, which shows eight again")
    func showAllTogglesShowLess() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): recentObjects(count: 10)]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }

        startPage.showAllClicks.accept(())
        #expect(try await nextValue(from: startPage.output.recentItems).count == 10)
        #expect(try await nextValue(from: startPage.output.showAllButton) == .showLess)
        #expect(ContentPlaceholderViewModel.ShowAllButton.showLess.title == "Show Less")

        startPage.showAllClicks.accept(())
        #expect(try await nextValue(from: startPage.output.recentItems).count == 8)
        #expect(try await nextValue(from: startPage.output.showAllButton) == .showAll)
    }

    @Test("Show All stays on while the list changes, and goes off when the page shows again")
    func showAllStaysOnUntilThePageShowsAgain() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): recentObjects(count: 9)]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }
        startPage.showAllClicks.accept(())
        #expect(startPage.viewModel.recentItems.count == 9)

        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): recentObjects(count: 10)]
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 10 }
        #expect(startPage.viewModel.showAllButton == .showLess)

        startPage.pageAppearances.accept(())
        #expect(startPage.viewModel.recentItems.count == 8)
        #expect(startPage.viewModel.showAllButton == .showAll)
    }

    @Test("going from one empty tab to another starts the page over")
    func anotherEmptyTabStartsThePageOver() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): recentObjects(count: 10)]
        let startPage = makeStartPage(in: environment, editorPaneID: environment.documentState.editorArea.focusedPaneID)
        defer { withExtendedLifetime(startPage) {} }
        var startedOverCount = 0
        let disposeBag = DisposeBag()
        startPage.output.startedOver.emitOnNext { startedOverCount += 1 }.disposed(by: disposeBag)
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }
        startPage.showAllClicks.accept(())
        #expect(startPage.viewModel.showAllButton == .showLess)

        environment.documentState.selectionRouter.trigger(.newTab)

        #expect(startPage.viewModel.showAllButton == .showAll)
        #expect(startPage.viewModel.recentItems.count == 8)
        #expect(startedOverCount == 1)
    }

    // MARK: - Opening

    @Test("opening a recent object focuses the page's pane and shows the object in its tab")
    func openingFocusesThePaneAndShowsTheObject() async throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState
        let object = Fixtures.runtimeObject(name: "Opened")
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): [object]]
        let pagePaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        #expect(documentState.editorArea.focusedPaneID != pagePaneID)
        let startPage = makeStartPage(in: environment, editorPaneID: pagePaneID)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .focusedTab))

        #expect(documentState.editorArea.focusedPaneID == pagePaneID)
        #expect(documentState.editorArea[pagePaneID]?.activeTab.object == object)
        #expect(documentState.selectedRuntimeObject == object)
    }

    @Test("opening in a new tab adds a tab to the page's pane")
    func openingInANewTabAddsATab() async throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState
        let object = Fixtures.runtimeObject(name: "Opened")
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): [object]]
        let pagePaneID = documentState.editorArea.focusedPaneID
        let startPage = makeStartPage(in: environment, editorPaneID: pagePaneID)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .newTab))

        let pane = try #require(documentState.editorArea[pagePaneID])
        #expect(pane.tabs.count == 2)
        #expect(pane.activeTab.object == object)
    }

    @Test("opening in the next pane goes to the pane after the page's, wherever the focus was")
    func openingInTheNextPane() async throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState
        let object = Fixtures.runtimeObject(name: "Opened")
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): [object]]
        let firstPaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        let secondPaneID = documentState.editorArea.focusedPaneID
        documentState.selectionRouter.trigger(.newEditorPane(.onRight))
        let thirdPaneID = documentState.editorArea.focusedPaneID
        #expect(Set([firstPaneID, secondPaneID, thirdPaneID]).count == 3)
        let startPage = makeStartPage(in: environment, editorPaneID: firstPaneID)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .nextEditorPane))

        let orderedPaneIDs = documentState.editorArea.orderedPanes.map(\.id)
        let firstPaneIndex = try #require(orderedPaneIDs.firstIndex(of: firstPaneID))
        let paneAfterFirst = orderedPaneIDs[firstPaneIndex + 1]
        #expect(documentState.editorArea.focusedPaneID == paneAfterFirst)
        #expect(documentState.editorArea[paneAfterFirst]?.activeTab.object == object)
        #expect(documentState.editorArea[firstPaneID]?.activeTab.object == nil)
    }

    @Test("an object a tab shows already opens in that tab's form, children and all")
    func objectShownInATabOpensInThatForm() async throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState
        let specialized = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Generic<Int>")])
        documentState.selectionRouter.trigger(.open(specialized, in: .focusedTab))
        let shownTabID = documentState.editorArea.focusedPane.activeTab.id
        documentState.selectionRouter.trigger(.newTab)
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): [specialized.withChildren([])]]
        let startPage = makeStartPage(in: environment, editorPaneID: documentState.editorArea.focusedPaneID)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .focusedTab))

        #expect(documentState.selectedRuntimeObject?.children.count == 1)
        let shownTab = try #require(documentState.editorArea.focusedPane.tabs.first { $0.id == shownTabID })
        #expect(shownTab.object?.children.count == 1)
    }

    @Test("an object a tab shows in another language still opens in that tab's form")
    func objectShownInAnotherLanguageOpensInThatForm() async throws {
        let environment = ViewModelTestEnvironment()
        let documentState = environment.documentState
        let specialized = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Generic<Int>")])
        documentState.selectionRouter.trigger(.open(specialized, in: .focusedTab, interfaceLanguage: .swift))
        documentState.selectionRouter.trigger(.newTab)
        environment.appDefaults.recentRuntimeObjectsByEngine = [engineKey(of: environment): [specialized.withChildren([])]]
        let startPage = makeStartPage(in: environment, editorPaneID: documentState.editorArea.focusedPaneID)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .focusedTab))

        #expect(documentState.selectedRuntimeObject?.children.count == 1)
    }
}

#endif
