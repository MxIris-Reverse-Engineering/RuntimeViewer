#if os(macOS)

import Foundation
import Testing
@testable import RuntimeViewerCore
import RuntimeViewerArchitectures
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport
import RuntimeViewerSettings

/// The start page an empty editor pane shows (proposal `editor-start-page`), driven through
/// `ContentPlaceholderViewModel`: the engine's recent images while the sidebar is at its image list,
/// and the recent objects of the image the sidebar is in.
@Suite("Start page", .serialized)
@MainActor
struct ContentStartPageViewModelTests {
    /// A start page under test. The view model holds its router `unowned`, so the page keeps both.
    private struct StartPage {
        let router: MockRouter<ContentRoute>
        let viewModel: ContentPlaceholderViewModel
        let output: ContentPlaceholderViewModel.Output
        let showAllClicks: PublishRelay<Void>
        let recentItemOpenings: PublishRelay<ContentStartPageItemOpening>
        let pageAppearances: PublishRelay<Void>
    }

    private func makeStartPage(in environment: ViewModelTestEnvironment, editorPaneID: EditorPane.ID? = nil) -> StartPage {
        let router = MockRouter<ContentRoute>()
        let viewModel = environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: router, editorPaneID: editorPaneID)
        }
        let showAllClicks = PublishRelay<Void>()
        let recentItemOpenings = PublishRelay<ContentStartPageItemOpening>()
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

    /// Records `objects` as the recent objects of the sample image, the only recent image, on the
    /// engine of `environment`.
    private func recordRecentObjects(_ objects: [RuntimeObject], in environment: ViewModelTestEnvironment) {
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: objects)],
        ]
    }

    private let otherImagePath = "/usr/lib/libOther.dylib"

    private let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [Fixtures.sampleImagePath, "/usr/lib/libOther.dylib"])

    /// Takes the sidebar of `environment` into the image at `imagePath`.
    private func enterImage(at imagePath: String = Fixtures.sampleImagePath, in environment: ViewModelTestEnvironment) throws {
        environment.documentState.selectionRouter.trigger(.switchImage(try #require(imageTree.leaf(forImagePath: imagePath))))
    }

    // MARK: - Levels

    @Test("with the sidebar at its image list the page lists the engine's recent images under Recent Images")
    func sidebarAtTheImageListListsRecentImages() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [
                RecentRuntimeImage(imagePath: otherImagePath),
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "NotListed")]),
            ],
        ]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }

        #expect(recentItems.map(\.item) == [.image(path: otherImagePath), .image(path: Fixtures.sampleImagePath)])
        #expect(recentItems.first?.appearance.title == "libOther.dylib")
        #expect(ContentPlaceholderViewModel.recentImagesTitle == "Recent Images")
        // The title starts as Recent Images: only one that went to Recent Objects and back shows
        // that it follows the sidebar.
        try enterImage(in: environment)
        _ = try await nextValue(from: startPage.output.recentItemsTitle) { $0 == ContentPlaceholderViewModel.recentObjectsTitle }
        environment.documentState.selectionRouter.trigger(.switchImage(nil))
        _ = try await nextValue(from: startPage.output.recentItemsTitle) { $0 == ContentPlaceholderViewModel.recentImagesTitle }
    }

    @Test("with the sidebar in an image the page lists only that image's recent objects under Recent Objects")
    func sidebarInAnImageListsItsRecentObjects() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [
                RecentRuntimeImage(imagePath: otherImagePath, objects: [Fixtures.runtimeObject(name: "InOther", imagePath: otherImagePath)]),
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "InSample")]),
            ],
        ]
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }

        #expect(recentItems.map(\.appearance.title) == ["InSample"])
        #expect(try await nextValue(from: startPage.output.recentItemsTitle) == "Recent Objects")
        #expect(ContentPlaceholderViewModel.recentObjectsTitle == "Recent Objects")
    }

    @Test("the sidebar going into another image, or back to the image list, changes the list")
    func sidebarMovingChangesTheList() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [
                RecentRuntimeImage(imagePath: otherImagePath, objects: [Fixtures.runtimeObject(name: "InOther", imagePath: otherImagePath)]),
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "InSample")]),
            ],
        ]
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "InSample" }

        try enterImage(at: otherImagePath, in: environment)
        let otherImageItems = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "InOther" }
        environment.documentState.selectionRouter.trigger(.switchImage(nil))
        let imageItems = try await nextValue(from: startPage.output.recentItems) { $0.first?.item == .image(path: self.otherImagePath) }

        #expect(otherImageItems.map(\.appearance.title) == ["InOther"])
        #expect(imageItems.count == 2)
        #expect(startPage.viewModel.recentItemsTitle == "Recent Images")
    }

    @Test("the sidebar moving to another level turns Show All off")
    func sidebarMovingTurnsShowAllOff() async throws {
        let environment = ViewModelTestEnvironment()
        let imagePaths = [Fixtures.sampleImagePath] + (0 ..< 9).map { "/usr/lib/libImage\($0).dylib" }
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): imagePaths.map { RecentRuntimeImage(imagePath: $0, objects: []) },
        ]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }
        startPage.showAllClicks.accept(())
        #expect(startPage.viewModel.showAllButton == .showLess)

        try enterImage(in: environment)
        environment.documentState.selectionRouter.trigger(.switchImage(nil))

        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }
        #expect(startPage.viewModel.showAllButton == .showAll)
    }

    @Test("the sidebar going from one image to another turns Show All off")
    func sidebarGoingToAnotherImageTurnsShowAllOff() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [
                RecentRuntimeImage(imagePath: otherImagePath, objects: (0 ..< 10).map { Fixtures.runtimeObject(name: "Other\($0)", imagePath: otherImagePath) }),
                RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: recentObjects(count: 10)),
            ],
        ]
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }
        startPage.showAllClicks.accept(())
        #expect(startPage.viewModel.showAllButton == .showLess)

        try enterImage(at: otherImagePath, in: environment)

        let otherImageItems = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "Other0" }
        #expect(otherImageItems.count == 8)
        #expect(startPage.viewModel.showAllButton == .showAll)
    }

    @Test("on an iOS Simulator engine the image the sidebar is in lists the objects filed under its root's path")
    func simulatorImageListsItsObjects() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "ContentStartPageViewModelTests.simulator")
        engine.setDyldRootPathForTesting("/sim_root")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [
                RecentRuntimeImage(imagePath: rootedSamplePath, objects: [Fixtures.runtimeObject(name: "Filed", imagePath: rootedSamplePath)]),
            ],
        ]
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }

        #expect(recentItems.map(\.appearance.title) == ["Filed"])
    }

    @Test("an image the sidebar went into before the engine learned its root lists its objects from the next record")
    func listCatchesUpWithTheEnginesSpellingAtTheNextRecord() async throws {
        let engine = RuntimeEngine(source: .local, engineID: "ContentStartPageViewModelTests.lateRoot")
        let environment = ViewModelTestEnvironment(runtimeEngine: engine)
        let rootedSamplePath = "/sim_root" + Fixtures.sampleImagePath
        let filedImages = [RecentRuntimeImage(imagePath: rootedSamplePath, objects: [Fixtures.runtimeObject(name: "Filed", imagePath: rootedSamplePath)])]
        environment.appDefaults.recentRuntimeImagesByEngine = [engineKey(of: environment): filedImages]
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItemsTitle) { $0 == ContentPlaceholderViewModel.recentObjectsTitle }
        #expect(startPage.viewModel.recentItems.isEmpty)

        engine.setDyldRootPathForTesting("/sim_root")
        environment.appDefaults.recentRuntimeImagesByEngine = [engineKey(of: environment): filedImages + [RecentRuntimeImage(imagePath: otherImagePath)]]

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }
        #expect(recentItems.map(\.appearance.title) == ["Filed"])
    }

    @Test("opening a recent image shows its image page")
    func openingARecentImageShowsItsPage() async throws {
        let environment = ViewModelTestEnvironment()
        environment.appDefaults.recentRuntimeImagesByEngine = [engineKey(of: environment): [RecentRuntimeImage(imagePath: otherImagePath)]]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .focusedTab))

        #expect(environment.documentState.editorArea.focusedPane.activeTab.imagePath == otherImagePath)
        #expect(environment.documentState.currentImageNode == nil)
    }

    // MARK: - Objects of an image

    @Test("the start page lists the image's recent objects, most recent first")
    func listsTheEnginesRecentObjects() async throws {
        let environment = ViewModelTestEnvironment()
        try enterImage(in: environment)
        recordRecentObjects([Fixtures.runtimeObject(name: "Second"), Fixtures.runtimeObject(name: "First")], in: environment)
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
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let output = startPage.output

        recordRecentObjects([Fixtures.runtimeObject(name: "Recorded")], in: environment)

        let recentItems = try await nextValue(from: output.recentItems) { !$0.isEmpty }
        #expect(recentItems.map(\.appearance.title) == ["Recorded"])
    }

    @Test("another engine's recent objects are not listed")
    func anotherEnginesRecentObjectsAreNotListed() async throws {
        let environment = ViewModelTestEnvironment()
        try enterImage(in: environment)
        environment.appDefaults.recentRuntimeImagesByEngine = [
            "scope:another-engine": [RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "Elsewhere")])],
            engineKey(of: environment): [RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "Here")])],
        ]
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }
        #expect(recentItems.map(\.appearance.title) == ["Here"])
    }

    @Test("a record on another engine leaves the list as it is")
    func recordOnAnotherEngineLeavesTheList() async throws {
        let environment = ViewModelTestEnvironment()
        try enterImage(in: environment)
        recordRecentObjects([Fixtures.runtimeObject(name: "Here")], in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let listed = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }

        environment.appDefaults.recentRuntimeImagesByEngine["scope:another-engine"] = [RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "Elsewhere")])]
        environment.appDefaults.recentRuntimeImagesByEngine[engineKey(of: environment)] = [
            RecentRuntimeImage(imagePath: Fixtures.sampleImagePath, objects: [Fixtures.runtimeObject(name: "Next"), Fixtures.runtimeObject(name: "Here")]),
        ]

        let relisted = try await nextValue(from: startPage.output.recentItems) { $0.first?.appearance.title == "Next" }
        #expect(relisted.map(\.appearance.title) == ["Next", "Here"])
        #expect(listed.map(\.appearance.title) == ["Here"])
    }

    @Test("a window moved to another engine from inside an image lists that engine's recent images")
    func windowMovedToAnotherEngineListsItsImages() async throws {
        let environment = ViewModelTestEnvironment()
        let otherEngine = TestRuntimeEngine.makeUnreachable()
        let otherEngineKey = Settings.Indexing.EngineReference.key(for: otherEngine)
        environment.appDefaults.recentRuntimeImagesByEngine = [
            engineKey(of: environment): [RecentRuntimeImage(imagePath: Fixtures.sampleImagePath)],
            otherEngineKey: [RecentRuntimeImage(imagePath: otherImagePath)],
        ]
        try enterImage(in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItemsTitle) { $0 == ContentPlaceholderViewModel.recentObjectsTitle }

        environment.documentState.selectionRouter.trigger(.switchEngine(otherEngine))

        let recentItems = try await nextValue(from: startPage.output.recentItems) { $0.first?.item == .image(path: self.otherImagePath) }
        #expect(recentItems.map(\.item) == [.image(path: otherImagePath)])
        #expect(startPage.viewModel.recentItemsTitle == ContentPlaceholderViewModel.recentImagesTitle)
    }

    // MARK: - Show All

    @Test("more recent objects than the default row count show the first eight and Show All")
    func moreThanEightShowEightAndShowAll() async throws {
        let environment = ViewModelTestEnvironment()
        try enterImage(in: environment)
        recordRecentObjects(recentObjects(count: 10), in: environment)
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
        try enterImage(in: environment)
        recordRecentObjects(recentObjects(count: 8), in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }

        let recentItems = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }
        #expect(recentItems.count == 8)
        #expect(try await nextValue(from: startPage.output.showAllButton) == .hidden)
    }

    @Test("Show All shows every recent object and becomes Show Less, which shows eight again")
    func showAllTogglesShowLess() async throws {
        let environment = ViewModelTestEnvironment()
        try enterImage(in: environment)
        recordRecentObjects(recentObjects(count: 10), in: environment)
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
        try enterImage(in: environment)
        recordRecentObjects(recentObjects(count: 9), in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 8 }
        startPage.showAllClicks.accept(())
        #expect(startPage.viewModel.recentItems.count == 9)

        recordRecentObjects(recentObjects(count: 10), in: environment)
        _ = try await nextValue(from: startPage.output.recentItems) { $0.count == 10 }
        #expect(startPage.viewModel.showAllButton == .showLess)

        startPage.pageAppearances.accept(())
        #expect(startPage.viewModel.recentItems.count == 8)
        #expect(startPage.viewModel.showAllButton == .showAll)
    }

    @Test("going from one empty tab to another starts the page over")
    func anotherEmptyTabStartsThePageOver() async throws {
        let environment = ViewModelTestEnvironment()
        try enterImage(in: environment)
        recordRecentObjects(recentObjects(count: 10), in: environment)
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
        try enterImage(in: environment)
        let documentState = environment.documentState
        let object = Fixtures.runtimeObject(name: "Opened")
        recordRecentObjects([object], in: environment)
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
        try enterImage(in: environment)
        let documentState = environment.documentState
        let object = Fixtures.runtimeObject(name: "Opened")
        recordRecentObjects([object], in: environment)
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
        try enterImage(in: environment)
        let documentState = environment.documentState
        let object = Fixtures.runtimeObject(name: "Opened")
        recordRecentObjects([object], in: environment)
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
        try enterImage(in: environment)
        let documentState = environment.documentState
        let specialized = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Generic<Int>")])
        documentState.selectionRouter.trigger(.open(specialized, in: .focusedTab))
        let shownTabID = documentState.editorArea.focusedPane.activeTab.id
        documentState.selectionRouter.trigger(.newTab)
        recordRecentObjects([specialized.withChildren([])], in: environment)
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
        try enterImage(in: environment)
        let documentState = environment.documentState
        let specialized = Fixtures.runtimeObject(name: "Generic", children: [Fixtures.runtimeObject(name: "Generic<Int>")])
        documentState.selectionRouter.trigger(.open(specialized, in: .focusedTab, interfaceLanguage: .swift))
        documentState.selectionRouter.trigger(.newTab)
        recordRecentObjects([specialized.withChildren([])], in: environment)
        let startPage = makeStartPage(in: environment, editorPaneID: documentState.editorArea.focusedPaneID)
        defer { withExtendedLifetime(startPage) {} }
        let recentItem = try #require(try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }.first)

        startPage.recentItemOpenings.accept(.init(item: recentItem, destination: .focusedTab))

        #expect(documentState.selectedRuntimeObject?.children.count == 1)
    }
}

#endif
