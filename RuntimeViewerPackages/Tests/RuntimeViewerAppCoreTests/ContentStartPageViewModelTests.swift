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
    }

    private func makeStartPage(in environment: ViewModelTestEnvironment) -> StartPage {
        let router = MockRouter<ContentRoute>()
        let viewModel = environment.make {
            ContentPlaceholderViewModel(documentState: environment.documentState, router: router)
        }
        return StartPage(router: router, viewModel: viewModel, output: viewModel.transform(.init()))
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
}

#endif
