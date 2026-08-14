import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Pins that *every* terminal outcome of `reloadData()` invalidates the
/// state a subclass derived from the previous object list — not only the
/// outcome that installs nodes.
///
/// The invalidation used to live in a `SidebarRuntimeObjectListViewModel`
/// override of `reloadData()` that ran after `super.reloadData()` returned,
/// so it covered the `.notLoaded` early return too — that path returns, it
/// does not throw. Moving it into a hook called from the install block
/// closed the main-actor window between installing nodes and invalidating,
/// but dropped the `.notLoaded` and `.loadError` outcomes on the way: an
/// Open Quickly pass scheduled before the reload then keeps its generation
/// token valid and publishes rows for an image the engine no longer reports
/// as loaded, the search string is never cleared, and the whole Open
/// Quickly index stays resident for the document's life.
@Suite("Sidebar reload invalidation", .serialized)
@MainActor
struct SidebarReloadInvalidationTests {
    /// The view model subscribes to the shared local engine's data-change
    /// channel; its one-shot startup broadcast would otherwise land inside
    /// whichever test is running (see SharedLocalEngineTestLock.swift).
    init() async {
        await ensureSharedLocalEngineSettled()
    }

    @Test("a reload that finds the image unloaded still invalidates derived state")
    func notLoadedReloadInvalidatesDerivedState() async throws {
        try await withSharedLocalEngineLock {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let documentState = DocumentState()
            let viewModel = InvalidationCountingListViewModel(
                imageNode: Self.makeNeverLoadedImageNode(),
                documentState: documentState,
                router: router
            )

            let reachedNotLoaded = try await pollUntil(timeout: .seconds(30)) {
                viewModel.loadState == .notLoaded
            }
            #expect(
                reachedNotLoaded,
                "the fixture image resolved as loaded, so this never exercised the early return; state=\(viewModel.loadState)"
            )
            #expect(
                viewModel.invalidateNodeDerivedStateCount >= 1,
                "the .notLoaded outcome ended the reload without invalidating derived state"
            )
        }
    }

    /// An image path the local engine can never report as loaded, so
    /// `reloadData()` is guaranteed to take the `.notLoaded` early return
    /// rather than racing a real image's load state.
    private static func makeNeverLoadedImageNode() -> RuntimeImageNode {
        let rootImageNode = RuntimeImageNode.rootNode(
            for: ["/RuntimeViewerTests/NeverLoaded.framework/NeverLoaded"],
            name: "Root"
        )
        var leafImageNode = rootImageNode
        while let firstChild = leafImageNode.children.first {
            leafImageNode = firstChild
        }
        // `parent` is weak and `absolutePath` derives from it lazily, so the
        // path has to be materialized while the root still owns the ancestor
        // chain.
        withExtendedLifetime(rootImageNode) {
            _ = leafImageNode.absolutePath
        }
        return leafImageNode
    }
}

/// Counts hook invocations instead of asserting on the Open Quickly fields
/// directly: the `.notLoaded` path never installs nodes, so those fields
/// are already empty and asserting on them would pass with or without the
/// fix. What regressed is whether the hook runs at all.
private final class InvalidationCountingListViewModel: SidebarRuntimeObjectListViewModel {
    private(set) var invalidateNodeDerivedStateCount = 0

    override func invalidateNodeDerivedState() {
        super.invalidateNodeDerivedState()
        invalidateNodeDerivedStateCount += 1
    }
}
