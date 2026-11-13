import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The object pages remember their Filter Scope per engine and image, share it
/// between the image's pages, and remember the Match Case toggle for every
/// image (proposal `filter-scope-memory`).
@Suite("Sidebar Filter Scope memory")
@MainActor
struct SidebarRuntimeObjectScopeMemoryTests {
    private let router = MockRouter<SidebarRuntimeObjectRoute>()

    private var excludingNotExported: RuntimeObjectScope {
        var scope = RuntimeObjectScope()
        scope[.notExported] = .exclude
        return scope
    }

    @Test("a page opened on an image starts with the scope remembered for that engine and image")
    func pageStartsWithRememberedScope() async throws {
        let harness = try await Harness.make()
        harness.environment.appDefaults.runtimeObjectScopesByEngineAndImagePath = harness.libobjcMemory.remembering(excludingNotExported, in: [:])

        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        let bookmarkViewModel = try harness.makeBookmarkViewModel(imagePath: TestImages.libobjc, router: router)
        let foundationViewModel = try harness.makeListViewModel(imagePath: TestImages.foundation, router: router)
        defer { withExtendedLifetime((listViewModel, bookmarkViewModel, foundationViewModel)) {} }

        #expect(listViewModel.scope == excludingNotExported)
        #expect(bookmarkViewModel.scope == excludingNotExported)
        #expect(foundationViewModel.scope == RuntimeObjectScope(), "another image picked up libobjc's scope")
    }

    @Test("a scope the user sets is remembered for the engine and image")
    func scopeChangeIsRemembered() async throws {
        let harness = try await Harness.make()
        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        defer { withExtendedLifetime(listViewModel) {} }

        // What the scope popover does: it edits the relay the page hands it.
        listViewModel.$scope.accept(excludingNotExported)

        #expect(harness.libobjcMemory.scope(in: harness.environment.appDefaults.runtimeObjectScopesByEngineAndImagePath) == excludingNotExported)
    }

    @Test("the image's other page follows a scope set on one of them")
    func otherPageFollows() async throws {
        let harness = try await Harness.make()
        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        let bookmarkViewModel = try harness.makeBookmarkViewModel(imagePath: TestImages.libobjc, router: router)
        let foundationViewModel = try harness.makeListViewModel(imagePath: TestImages.foundation, router: router)
        defer { withExtendedLifetime((listViewModel, bookmarkViewModel, foundationViewModel)) {} }

        listViewModel.$scope.accept(excludingNotExported)

        let followedScope = try await nextValue(from: bookmarkViewModel.$scope) { $0 == self.excludingNotExported }
        #expect(followedScope == excludingNotExported)
        #expect(foundationViewModel.scope == RuntimeObjectScope(), "a page on another image followed")
    }

    @Test("resetting the scope forgets it, and the other page follows")
    func resetForgetsTheScope() async throws {
        let harness = try await Harness.make()
        harness.environment.appDefaults.runtimeObjectScopesByEngineAndImagePath = harness.libobjcMemory.remembering(excludingNotExported, in: [:])
        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        let bookmarkViewModel = try harness.makeBookmarkViewModel(imagePath: TestImages.libobjc, router: router)
        defer { withExtendedLifetime((listViewModel, bookmarkViewModel)) {} }

        bookmarkViewModel.$scope.accept(RuntimeObjectScope())

        #expect(harness.environment.appDefaults.runtimeObjectScopesByEngineAndImagePath.isEmpty)
        _ = try await nextValue(from: listViewModel.$scope) { $0 == RuntimeObjectScope() }
    }

    @Test("a reveal that clears the scope forgets it too")
    func revealClearingTheScopeForgetsIt() async throws {
        let harness = try await Harness.make()
        harness.environment.appDefaults.runtimeObjectScopesByEngineAndImagePath = harness.libobjcMemory.remembering(excludingNotExported, in: [:])
        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        defer { withExtendedLifetime(listViewModel) {} }

        listViewModel.clearFilter()

        #expect(listViewModel.scope == RuntimeObjectScope())
        #expect(harness.environment.appDefaults.runtimeObjectScopesByEngineAndImagePath.isEmpty)
    }

    @Test("a page starts with the Match Case toggle as it was last left, and remembers a toggle")
    func matchCaseIsRemembered() async throws {
        let harness = try await Harness.make()
        harness.environment.appDefaults.isRuntimeObjectFilterCaseSensitive = true
        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        defer { withExtendedLifetime(listViewModel) {} }
        #expect(listViewModel.isSearchCaseSensitive)

        // The toggle starts where the view model is, as the view sets it.
        let matchCaseRelay = BehaviorRelay(value: listViewModel.isSearchCaseSensitive)
        _ = listViewModel.transform(Self.input(isSearchCaseSensitive: matchCaseRelay.asDriver()))

        matchCaseRelay.accept(false)

        _ = try await nextValue(from: listViewModel.$isSearchCaseSensitive) { !$0 }
        #expect(harness.environment.appDefaults.isRuntimeObjectFilterCaseSensitive == false)
    }

    @Test("a page without the toggle leaves the remembered Match Case alone")
    func pageWithoutToggleLeavesMatchCaseAlone() async throws {
        let harness = try await Harness.make()
        harness.environment.appDefaults.isRuntimeObjectFilterCaseSensitive = true
        let listViewModel = try harness.makeListViewModel(imagePath: TestImages.libobjc, router: router)
        defer { withExtendedLifetime(listViewModel) {} }

        _ = listViewModel.transform(Self.input(isSearchCaseSensitive: .just(false)))

        _ = try await nextValue(from: listViewModel.$isSearchCaseSensitive) { !$0 }
        #expect(harness.environment.appDefaults.isRuntimeObjectFilterCaseSensitive)
    }

    // MARK: - Helpers

    private static func input(isSearchCaseSensitive: Driver<Bool>) -> SidebarRuntimeObjectViewModel.Input {
        SidebarRuntimeObjectViewModel.Input(
            runtimeObjectClicked: .empty(),
            runtimeObjectOpenedInNewTab: .empty(),
            loadImageClicked: .empty(),
            filter: .just(.empty),
            isSearchCaseSensitive: isSearchCaseSensitive
        )
    }

    @MainActor
    private struct Harness {
        let engine: RuntimeEngine
        let environment: ViewModelTestEnvironment
        let imageTree: RuntimeImageNode

        var libobjcMemory: RuntimeObjectScopeMemory {
            RuntimeObjectScopeMemory(engine: engine, imagePath: TestImages.libobjc)
        }

        static func make() async throws -> Harness {
            let engine = try await TestRuntimeEngine.shared()
            return Harness(
                engine: engine,
                environment: ViewModelTestEnvironment(runtimeEngine: engine),
                imageTree: Fixtures.imageTree(rootName: "Others", imagePaths: [TestImages.libobjc, TestImages.foundation])
            )
        }

        func makeListViewModel(imagePath: String, router: MockRouter<SidebarRuntimeObjectRoute>) throws -> SidebarRuntimeObjectListViewModel {
            let leaf = try #require(imageTree.leaf(forImagePath: imagePath))
            return environment.make {
                SidebarRuntimeObjectListViewModel(imageNode: leaf, documentState: environment.documentState, router: router)
            }
        }

        func makeBookmarkViewModel(imagePath: String, router: MockRouter<SidebarRuntimeObjectRoute>) throws -> SidebarRuntimeObjectBookmarkViewModel {
            let leaf = try #require(imageTree.leaf(forImagePath: imagePath))
            return environment.make {
                SidebarRuntimeObjectBookmarkViewModel(imageNode: leaf, documentState: environment.documentState, router: router)
            }
        }
    }
}
