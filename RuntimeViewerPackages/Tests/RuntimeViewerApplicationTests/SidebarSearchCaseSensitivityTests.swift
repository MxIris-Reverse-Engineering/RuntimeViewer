import Dependencies
import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Pins the polarity of the sidebar's Match Case toggle, from the `Input`
/// driver down to the matching.
///
/// The control is the filter field's `textformat` ("Aa") button. It used to
/// read "Case Insensitive" and start selected, so highlighting it *relaxed*
/// the search — the reverse of what the same icon means in Xcode, VS Code
/// and Safari, and the reverse of what a highlighted filter button means
/// everywhere else in this field. It now reads "Match Case" and starts
/// unselected, which puts a negation between the UI flag and
/// `FilterContext.isCaseInsensitive`; `scheduleRefilter()` is the only
/// place that negation lives.
///
/// `FilterEngineCaseSensitivityTests` pins the engine's own semantics.
/// This suite pins the mapping onto them — the half that has now been
/// inverted twice (once in the engine, once in the control) and that no
/// engine-level test can see.
@Suite("SidebarSearchCaseSensitivity", .serialized)
@MainActor
struct SidebarSearchCaseSensitivityTests {
    /// The view model subscribes to the shared local engine's data-change
    /// channel; its one-shot startup broadcast would otherwise land inside
    /// whichever test is running (see SharedLocalEngineTestLock.swift).
    init() async {
        await ensureSharedLocalEngineSettled()
    }

    @Test("Match Case off matches a differently-cased query")
    func matchCaseOffIgnoresCase() async throws {
        try await withSharedLocalEngineLock {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let viewModel = try await makeLoadedViewModel(router: router)

            let searchStringRelay = PublishRelay<String>()
            _ = viewModel.transform(
                makeInput(searchString: searchStringRelay, isSearchCaseSensitive: .just(false))
            )

            searchStringRelay.accept("needle")

            let matched = try await pollUntil(timeout: .seconds(10)) {
                filteredDisplayNames(of: viewModel) == ["CaseNeedle", "caseneedle"]
            }
            #expect(
                matched,
                """
                an unselected Match Case toggle must ignore case; \
                got \(filteredDisplayNames(of: viewModel))
                """
            )
            #expect(viewModel.isSearchCaseSensitive == false)
        }
    }

    @Test("Match Case on requires the query's own case")
    func matchCaseOnRequiresExactCase() async throws {
        try await withSharedLocalEngineLock {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let viewModel = try await makeLoadedViewModel(router: router)

            let searchStringRelay = PublishRelay<String>()
            _ = viewModel.transform(
                makeInput(searchString: searchStringRelay, isSearchCaseSensitive: .just(true))
            )

            searchStringRelay.accept("needle")

            let lowercaseMatched = try await pollUntil(timeout: .seconds(10)) {
                filteredDisplayNames(of: viewModel) == ["caseneedle"]
            }
            #expect(
                lowercaseMatched,
                """
                a selected Match Case toggle must reject the differently-cased row; \
                got \(filteredDisplayNames(of: viewModel))
                """
            )
            #expect(viewModel.isSearchCaseSensitive)

            // The complementary query, so the assertion above cannot pass
            // by matching nothing at all under some unrelated breakage.
            searchStringRelay.accept("Needle")

            let uppercaseMatched = try await pollUntil(timeout: .seconds(10)) {
                filteredDisplayNames(of: viewModel) == ["CaseNeedle"]
            }
            #expect(
                uppercaseMatched,
                """
                the capitalized query must match only the capitalized row; \
                got \(filteredDisplayNames(of: viewModel))
                """
            )
        }
    }

    // MARK: - Fixture

    /// Two rows differing only in case plus one non-match, so a pass that
    /// ignores the flag entirely fails whichever direction it defaults to.
    private static let caseFixtureRuntimeObjects: [RuntimeObject] = ["CaseNeedle", "caseneedle", "Unrelated"].map { name in
        RuntimeObject(
            name: name,
            displayName: name,
            kind: .swift(.type(.class)),
            secondaryKind: nil,
            imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
            children: [],
            properties: []
        )
    }

    private func makeLoadedViewModel(
        router: MockRouter<SidebarRuntimeObjectRoute>
    ) async throws -> CaseFixtureSidebarViewModel {
        // Only the plain-contains mode (`filterMode == nil`, the sidebar's
        // default) consults the flag at all — both fuzzy modes ignore it —
        // so a mode persisted by an earlier run would turn this suite into
        // a no-op that still passes in one direction.
        withLiveDependencyContext {
            @Dependency(\.appDefaults) var appDefaults
            appDefaults.filterMode = nil
        }

        let viewModel = CaseFixtureSidebarViewModel(
            seededRuntimeObjects: Self.caseFixtureRuntimeObjects,
            imageNode: try await makeLoadedImageNode(),
            documentState: DocumentState(),
            router: router
        )
        let reloadFinished = try await pollUntil(timeout: .seconds(30)) {
            viewModel.loadState == .loaded
        }
        #expect(reloadFinished, "seeded reload never reached .loaded; state=\(viewModel.loadState)")
        #expect(viewModel.filteredNodes.count == Self.caseFixtureRuntimeObjects.count)
        return viewModel
    }

    private func makeInput(
        searchString: PublishRelay<String>,
        isSearchCaseSensitive: Driver<Bool>
    ) -> SidebarRuntimeObjectViewModel.Input {
        .init(
            runtimeObjectClicked: .never(),
            runtimeObjectOpenedInNewTab: .never(),
            loadImageClicked: .never(),
            searchString: searchString.asDriver(onErrorJustReturn: ""),
            isSearchCaseSensitive: isSearchCaseSensitive
        )
    }

    private func filteredDisplayNames(of viewModel: SidebarRuntimeObjectViewModel) -> [String] {
        viewModel.filteredNodes.map(\.runtimeObject.displayName)
    }
}

/// Serves a fixed object list so the filter, not the engine's view of the
/// host process, decides what the suite sees.
private final class CaseFixtureSidebarViewModel: SidebarRuntimeObjectViewModel {
    private let seededRuntimeObjects: [RuntimeObject]

    init(
        seededRuntimeObjects: [RuntimeObject],
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>
    ) {
        self.seededRuntimeObjects = seededRuntimeObjects
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        seededRuntimeObjects
    }
}
