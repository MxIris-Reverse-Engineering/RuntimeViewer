import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Pins that a rebuilt image tree invalidates the in-flight root filter
/// pass in the *same* main-actor turn that installs the new tree.
///
/// The two halves used to be separate subscriptions: `$nodes.bind(to:
/// $filteredNodes)` swapped the list synchronously, while the cancellation
/// and generation bump went through `subscribeOnNextMainActor` — which
/// expands to `Task { @MainActor in … }` and therefore only *enqueued*
/// them. A verdict continuation resuming in that window saw
/// `Task.isCancelled == false` and an unchanged generation, so it passed
/// both guards and republished the discarded cell tree over the fresh one.
/// Nothing reschedules a filter afterwards, so the sidebar kept showing
/// the previous tree until the user typed again.
///
/// The sibling `SidebarRuntimeObjectViewModel` bumps its generation
/// synchronously inside `scheduleRefilter()`, so only the root pipeline
/// ever had this hole.
///
/// Note on method: the assertions sample the generation counter from a
/// `$filteredNodes` observer rather than after the `accept` returns.
/// `observe(on: MainScheduler.instance)` only delivers synchronously while
/// the scheduler is idle, so an "assert right after accept" test passes
/// alone and fails under concurrent suites. Sampling at installation time
/// pins the ordering itself, independent of when the emission lands.
@Suite("SidebarRootFilterInvalidation", .serialized)
@MainActor
struct SidebarRootFilterInvalidationTests {
    @Test("an image-tree rebuild bumps the filter generation before installing the new tree")
    func rebuildBumpsFilterGenerationBeforeInstallingNodes() async throws {
        let harness = try await Harness(seededGeneration: 0)

        let generationBeforeRebuild = harness.viewModel.currentRootFilterGeneration
        harness.nodesRelay.accept(Harness.makeImageNodes(generation: 1))

        let installed = try await pollUntil(timeout: .seconds(5)) {
            harness.probe.generationAtInstallation != nil
        }
        #expect(installed, "the rebuilt tree was never installed into filteredNodes")
        #expect(
            harness.probe.generationAtInstallation != generationBeforeRebuild,
            "the rebuild deferred its invalidation; a verdict resuming before the enqueued bump would republish the discarded tree"
        )
        #expect(
            harness.viewModel.filteredNodes.map(\.node.name) == ["generation1"],
            "the rebuild must still drop the visual filter and install the new tree"
        )
    }

    /// Every emission must invalidate, not just the ones that change the
    /// contents: the cell view models are rebuilt per emission, so even an
    /// identical image list hands out a fresh tree that an older verdict
    /// must not be applied to.
    @Test("a rebuild carrying the same image names still invalidates")
    func rebuildWithIdenticalNamesStillInvalidates() async throws {
        let harness = try await Harness(seededGeneration: 0)

        let generationBeforeRebuild = harness.viewModel.currentRootFilterGeneration
        let cellsBeforeRebuild = harness.viewModel.nodes
        harness.nodesRelay.accept(Harness.makeImageNodes(generation: 0))

        let installed = try await pollUntil(timeout: .seconds(5)) {
            harness.probe.generationAtInstallation != nil
        }
        #expect(installed, "the rebuilt tree was never installed into filteredNodes")
        #expect(harness.probe.generationAtInstallation != generationBeforeRebuild)
        #expect(
            harness.viewModel.nodes.first !== cellsBeforeRebuild.first,
            "each emission is expected to hand out freshly built cell view models"
        )
    }

    /// Dropping the filter's *results* is only half the job — the flag has
    /// to come down with them.
    ///
    /// `didEndFiltering` derives from `isFiltering`, so leaving it set means
    /// `endFiltering()` is never called and the outline stays in
    /// `.filtering` for the rest of the session: every later rebuild
    /// re-runs `expandItem(nil, expandChildren: true)` over the whole image
    /// tree, and `scheduleExpansionPersist`'s `filteringState == .idle`
    /// guard keeps expansion autosave off. Nothing else lowers the flag
    /// except the user clearing the search field by hand.
    @Test("an image-tree rebuild leaves the sidebar out of filtering mode")
    func rebuildClearsTheFilteringFlag() async throws {
        let harness = try await Harness(seededGeneration: 0, wiringInput: true)

        harness.search("System")
        let filtering = try await pollUntil(timeout: .seconds(5)) {
            harness.viewModel.isFiltering
        }
        #expect(filtering, "the query never put the sidebar into filtering mode")

        harness.nodesRelay.accept(Harness.makeImageNodes(generation: 1))

        let installed = try await pollUntil(timeout: .seconds(5)) {
            harness.viewModel.filteredNodes.map(\.node.name) == ["generation1"]
        }
        #expect(installed, "the rebuilt tree was never installed into filteredNodes")
        #expect(
            !harness.viewModel.isFiltering,
            "the rebuild dropped the filter results but left the sidebar wedged in filtering mode"
        )
    }
}

// MARK: - Harness

extension SidebarRootFilterInvalidationTests {
    /// Records the filter generation as it stood when a rebuilt tree was
    /// installed into `filteredNodes` — the moment the invalidation must
    /// already have happened.
    @MainActor
    fileprivate final class InstallationProbe {
        var generationAtInstallation: Int?
    }

    @MainActor
    fileprivate struct Harness {
        let viewModel: SidebarRootViewModel
        let nodesRelay: BehaviorRelay<[RuntimeImageNode]>
        let probe = InstallationProbe()

        /// `ViewModel` holds its router `unowned`, so the mock must outlive
        /// every assertion.
        private let router: MockRouter<SidebarRootRoute>
        private let disposeBag = DisposeBag()
        private let searchStringRelay = PublishRelay<String>()

        /// Opt-in so the tests that only exercise rebuilds keep running
        /// against exactly the subscription set they were written for.
        init(seededGeneration: Int, wiringInput: Bool = false) async throws {
            let nodesRelay = BehaviorRelay<[RuntimeImageNode]>(value: Self.makeImageNodes(generation: seededGeneration))
            let router = MockRouter<SidebarRootRoute>()
            let viewModel = withLiveDependencyContext {
                SidebarRootViewModel(
                    documentState: DocumentState(),
                    router: router,
                    nodesSource: nodesRelay.asObservable()
                )
            }
            self.nodesRelay = nodesRelay
            self.router = router
            self.viewModel = viewModel

            let seeded = try await pollUntil(timeout: .seconds(5)) {
                viewModel.nodes.map(\.node.name) == ["generation\(seededGeneration)"]
            }
            #expect(seeded, "the view model never picked up the seeded image tree")

            if wiringInput {
                _ = viewModel.transform(
                    SidebarRootViewModel.Input(
                        clickedNode: .never(),
                        selectedNode: .never(),
                        searchString: searchStringRelay.asSignal()
                    )
                )
            }

            // Installed after the seeding so only rebuild-driven emissions
            // are recorded. This observer runs in the same synchronous step
            // as the view model's own `filteredNodes` assignment.
            let probe = probe
            viewModel.$filteredNodes
                .asObservable()
                .skip(1)
                .subscribeOnNext { [weak viewModel] _ in
                    MainActor.assumeIsolated {
                        probe.generationAtInstallation = viewModel?.currentRootFilterGeneration
                    }
                }
                .disposed(by: disposeBag)
        }

        func search(_ query: String) {
            searchStringRelay.accept(query)
        }

        static func makeImageNodes(generation: Int) -> [RuntimeImageNode] {
            let root = RuntimeImageNode("generation\(generation)")
            _ = root.child(named: "System")
            return [root]
        }
    }
}
