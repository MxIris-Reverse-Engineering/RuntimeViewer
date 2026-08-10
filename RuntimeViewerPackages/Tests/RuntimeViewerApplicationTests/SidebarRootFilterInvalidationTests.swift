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

        init(seededGeneration: Int) async throws {
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

        static func makeImageNodes(generation: Int) -> [RuntimeImageNode] {
            let root = RuntimeImageNode("generation\(generation)")
            _ = root.child(named: "System")
            return [root]
        }
    }
}
