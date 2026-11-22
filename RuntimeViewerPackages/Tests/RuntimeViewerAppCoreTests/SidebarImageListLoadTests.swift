#if os(macOS)

import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// `DocumentState.sidebarImageListLoad`: where the sidebar's object list of the image the sidebar
/// is in stands, which list is heard, and what the bookmarks page and the start page make of it.
/// That they wait for the list at all is pinned by `SidebarImageListLoadWaitTests`.
@Suite("Sidebar image list load", .serialized)
@MainActor
struct SidebarImageListLoadTests {
    private let sidebarRouter = MockRouter<SidebarRuntimeObjectRoute>()
    private let contentRouter = MockRouter<ContentRoute>()

    private let nsObject = Fixtures.runtimeObject(name: "NSObject", kind: .objc(.type(.class)), imagePath: TestImages.libobjc)

    private let imageTree = Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc, TestImages.foundation])

    private let swiftTypesProgress = RuntimeObjectsLoadingProgress(phase: .extractingSwiftTypes, itemDescription: "", currentCount: 120, totalCount: 3400)

    // MARK: - The document's report

    @Test("going into an image waits for its list before any list reports, and the list's load settles it")
    func goingIntoAnImageWaitsUntilTheListSettles() async throws {
        let environment = try await makeEnvironment()
        let imageNode = try enterImage(TestImages.libobjc, in: environment)

        #expect(environment.documentState.sidebarImageListLoad?.imagePath == TestImages.libobjc)
        #expect(environment.documentState.sidebarImageListLoad?.phase.isSettled == false)

        let list = makeList(for: imageNode, in: environment)
        defer { withExtendedLifetime(list) {} }
        try await waitUntil { list.isBuilding }
        #expect(environment.documentState.sidebarImageListLoad?.phase.isSettled == false)

        list.finishBuild(with: [nsObject])
        try await waitUntil { environment.documentState.sidebarImageListLoad?.phase.isSettled == true }
        #expect(environment.documentState.sidebarImageListLoad?.imagePath == TestImages.libobjc)
    }

    @Test("a list that cannot load the image settles too")
    func aFailedLoadSettles() async throws {
        let environment = try await makeEnvironment()
        let imageNode = try enterImage(TestImages.libobjc, in: environment)
        let list = makeList(for: imageNode, in: environment)
        defer { withExtendedLifetime(list) {} }
        try await waitUntil { list.isBuilding }

        list.failBuild()

        try await waitUntil { environment.documentState.sidebarImageListLoad?.phase.isSettled == true }
        guard case .loadError = list.loadState else {
            Issue.record("the failed build left the list \(list.loadState), not showing the error")
            return
        }
    }

    @Test("going back to the image list ends the report")
    func goingBackToTheImageListEndsTheReport() async throws {
        let environment = try await makeEnvironment()
        _ = try enterImage(TestImages.libobjc, in: environment)

        environment.documentState.selectionRouter.trigger(.switchImage(nil))

        #expect(environment.documentState.sidebarImageListLoad == nil)
    }

    @Test("only the list made last for the image is heard")
    func onlyTheLatestListIsHeard() async throws {
        let environment = try await makeEnvironment()
        _ = try enterImage(TestImages.libobjc, in: environment)
        let earlierReporter = environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.libobjc)
        let laterReporter = environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.libobjc)
        laterReporter.report(.loading(nil))

        earlierReporter.report(.settled)

        #expect(environment.documentState.sidebarImageListLoad?.phase.isSettled == false)
        laterReporter.report(.settled)
        #expect(environment.documentState.sidebarImageListLoad?.phase.isSettled == true)
    }

    @Test("a list of an image the sidebar is not in is never heard")
    func aListOfAnotherImageIsNotHeard() async throws {
        let environment = try await makeEnvironment()
        _ = try enterImage(TestImages.libobjc, in: environment)
        let reporter = environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.foundation)

        reporter.report(.settled)

        #expect(environment.documentState.sidebarImageListLoad?.imagePath == TestImages.libobjc)
        #expect(environment.documentState.sidebarImageListLoad?.phase.isSettled == false)
    }

    // MARK: - The bookmarks page

    @Test("the bookmarks page shows the list's progress while it waits")
    func bookmarksShowTheListsProgress() async throws {
        let environment = try await makeEnvironment()
        let imageNode = try enterImage(TestImages.libobjc, in: environment)
        let reporter = environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.libobjc)
        reporter.report(.loading(nil))
        let bookmarks = environment.make {
            SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, documentState: environment.documentState, router: sidebarRouter)
        }
        defer { withExtendedLifetime((reporter, bookmarks)) {} }

        reporter.report(.loading(swiftTypesProgress))

        let description = try await nextValue(from: bookmarks.$loadingDescription) { $0 == "Extracting Swift types..." }
        #expect(description == "Extracting Swift types...")
        #expect(bookmarks.loadingItemCount == "120/3400")
        #expect(bookmarks.loadState == .loading)

        reporter.report(.settled)
        _ = try await nextValue(from: bookmarks.$loadState) { $0 == .loaded }
    }

    @Test("the bookmarks page waits for nothing without a list")
    func bookmarksWithoutAListShowAtOnce() async throws {
        let environment = try await makeEnvironment()
        let imageNode = try #require(imageTree.leaf(forImagePath: TestImages.libobjc))
        let bookmarks = environment.make {
            SidebarRuntimeObjectBookmarkViewModel(imageNode: imageNode, documentState: environment.documentState, router: sidebarRouter)
        }
        defer { withExtendedLifetime(bookmarks) {} }

        _ = try await nextValue(from: bookmarks.$loadState) { $0 == .loaded }
    }

    // MARK: - The start page

    @Test("the start page gives way to the list's progress alone while it waits")
    func startPageWaitsWithTheListsProgress() async throws {
        let environment = try await makeEnvironment()
        recordRecentObjects([nsObject], in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try enterImage(TestImages.libobjc, in: environment)
        let reporter = environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.libobjc)
        defer { withExtendedLifetime(reporter) {} }

        reporter.report(.loading(swiftTypesProgress))

        _ = try await nextValue(from: startPage.output.placeholder) { $0 == .waitingForImageList }
        let progress = try await nextValue(from: startPage.output.imageListLoadingProgress) { $0 != .preparing }
        #expect(progress == ImageIndexingProgress(fraction: swiftTypesProgress.overallFraction, description: "Extracting Swift types...", itemCount: "120/3400"))
        #expect(startPage.viewModel.recentItems.isEmpty)
        #expect(startPage.viewModel.showAllButton == .hidden)

        reporter.report(.settled)
        _ = try await nextValue(from: startPage.output.placeholder) { $0 == .noSelection }
        // The list is in place by the time the page shows again.
        #expect(startPage.viewModel.recentItems.map(\.item) == [.object(nsObject)])
    }

    @Test("a list that loads quickly never shows the wait")
    func aQuickListShowsNoWait() async throws {
        let environment = try await makeEnvironment()
        recordRecentObjects([nsObject], in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        let placeholders = startPage.output.placeholder.asObservable().replayAll()
        let connection = placeholders.connect()
        defer { connection.dispose() }

        _ = try enterImage(TestImages.libobjc, in: environment)
        environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.libobjc).report(.settled)
        _ = try await nextValue(from: startPage.output.recentItems) { $0.map(\.item) == [.object(self.nsObject)] }

        let shownPlaceholders = try await values(from: placeholders, during: 0.3)
        #expect(!shownPlaceholders.contains(.waitingForImageList))
    }

    @Test("the list loading the image again brings the wait back")
    func loadingAgainBringsTheWaitBack() async throws {
        let environment = try await makeEnvironment()
        recordRecentObjects([nsObject], in: environment)
        let startPage = makeStartPage(in: environment)
        defer { withExtendedLifetime(startPage) {} }
        _ = try enterImage(TestImages.libobjc, in: environment)
        let reporter = environment.documentState.makeSidebarImageListLoadReporter(forImageAt: TestImages.libobjc)
        defer { withExtendedLifetime(reporter) {} }
        reporter.report(.settled)
        _ = try await nextValue(from: startPage.output.recentItems) { !$0.isEmpty }

        // The image was not loaded, and the user loads it from the sidebar.
        reporter.report(.loading(nil))

        _ = try await nextValue(from: startPage.output.placeholder) { $0 == .waitingForImageList }
        reporter.report(.settled)
        _ = try await nextValue(from: startPage.output.placeholder) { $0 == .noSelection }
        #expect(!startPage.viewModel.recentItems.isEmpty)
    }

    // MARK: - Helpers

    private struct StartPage {
        let viewModel: ContentPlaceholderViewModel
        let output: ContentPlaceholderViewModel.Output
    }

    private func makeEnvironment() async throws -> ViewModelTestEnvironment {
        ViewModelTestEnvironment(runtimeEngine: try await TestRuntimeEngine.shared())
    }

    private func makeList(for imageNode: RuntimeImageNode, in environment: ViewModelTestEnvironment) -> GatedSidebarListViewModel {
        environment.make {
            GatedSidebarListViewModel(imageNode: imageNode, documentState: environment.documentState, router: sidebarRouter)
        }
    }

    private func makeStartPage(in environment: ViewModelTestEnvironment) -> StartPage {
        let viewModel = environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: contentRouter)
        }
        return StartPage(viewModel: viewModel, output: viewModel.transform(.init()))
    }

    private func recordRecentObjects(_ objects: [RuntimeObject], in environment: ViewModelTestEnvironment) {
        environment.appDefaults.recentRuntimeImagesByEngine = [
            Settings.Indexing.EngineReference.key(for: environment.documentState.runtimeEngine): [
                RecentRuntimeImage(imagePath: TestImages.libobjc, objects: objects),
            ],
        ]
    }

    private func enterImage(_ imagePath: String, in environment: ViewModelTestEnvironment) throws -> RuntimeImageNode {
        let imageNode = try #require(imageTree.leaf(forImagePath: imagePath))
        environment.documentState.selectionRouter.trigger(.switchImage(imageNode))
        return imageNode
    }
}

#endif
