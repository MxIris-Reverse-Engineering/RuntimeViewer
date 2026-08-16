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

    /// The `.loadError` outcome has to drop the previous load's object
    /// list, not just re-derive from it.
    ///
    /// `invalidateNodeDerivedState()` re-seeds every derived field off
    /// `nodes`, and the failing reload never assigns `nodes` — so the
    /// invalidation clears the Open Quickly index and immediately rebuilds
    /// it from the load that already ended. The next keystroke then
    /// publishes rows for an image the engine has stopped standing behind,
    /// which is the exact publish the hook exists to prevent.
    ///
    /// This is also the only test in the target that drives a throwing
    /// reload at all: with it absent, deleting the `.loadError` call site
    /// left the whole suite green.
    @Test("a reload that fails drops the object list the previous load published")
    func failedReloadDropsThePreviousLoadsOpenQuicklyIndex() async throws {
        try await withSharedLocalEngineLock {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let searchStringRelay = PublishRelay<String>()
            let viewModel = FailableSeededListViewModel(
                seededRuntimeObjects: Self.makeSeededRuntimeObjects(),
                imageNode: try await makeLoadedImageNode(),
                documentState: DocumentState(),
                router: router
            )

            let loaded = try await pollUntil(timeout: .seconds(30)) {
                viewModel.loadState == .loaded
            }
            #expect(loaded, "the seeded reload never reached .loaded; state=\(viewModel.loadState)")

            _ = viewModel.transform(
                SidebarRuntimeObjectListViewModel.Input(
                    runtimeObjectClickedForOpenQuickly: .never(),
                    searchStringForOpenQuickly: searchStringRelay.asSignal(),
                    addBookmark: .never()
                )
            )
            // The stream drops its first element (the search field's initial
            // value in the real UI), so prime it before querying.
            searchStringRelay.accept("")

            searchStringRelay.accept("Seeded")
            let answered = try await pollUntil(timeout: .seconds(20)) {
                !viewModel.filteredNodesForOpenQuickly.isEmpty
            }
            #expect(answered, "the Open Quickly index never answered a query for the loaded image")

            viewModel.failNextReload()
            viewModel.scheduleReload()
            let failed = try await pollUntil(timeout: .seconds(30)) {
                if case .loadError = viewModel.loadState { return true }
                return false
            }
            #expect(failed, "the reload never reached .loadError; state=\(viewModel.loadState)")

            searchStringRelay.accept("Seeded")
            // Long enough for the debounce, the haystack build and the apply
            // hop; the assertion is that nothing arrives, so it cannot poll.
            try await Task.sleep(for: .milliseconds(1_500))
            #expect(
                viewModel.filteredNodesForOpenQuickly.isEmpty,
                "a query after the failed reload still published rows built from the previous load's object list"
            )
        }
    }

    private static func makeSeededRuntimeObjects() -> [RuntimeObject] {
        (0 ..< 32).map { index in
            RuntimeObject(
                name: "SeededType\(index)",
                displayName: "SeededType\(index)",
                kind: .swift(.type(.class)),
                secondaryKind: nil,
                imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
                children: [],
                properties: []
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

/// Serves a seeded object list until `failNextReload()` is called, then
/// finishes the stream with an error so `scheduleReload()`'s generic
/// `catch` — the `.loadError` outcome — runs.
private final class FailableSeededListViewModel: SidebarRuntimeObjectListViewModel {
    private enum ReloadFailure: Error {
        case injected
    }

    private let seededRuntimeObjects: [RuntimeObject]
    private var shouldFailNextReload = false

    init(
        seededRuntimeObjects: [RuntimeObject],
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>
    ) {
        self.seededRuntimeObjects = seededRuntimeObjects
        super.init(imageNode: imageNode, documentState: documentState, router: router)
    }

    func failNextReload() {
        shouldFailNextReload = true
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        if shouldFailNextReload {
            throw ReloadFailure.injected
        }
        return seededRuntimeObjects
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { [seededRuntimeObjects, shouldFailNextReload] continuation in
            if shouldFailNextReload {
                continuation.finish(throwing: ReloadFailure.injected)
            } else {
                continuation.yield(.completed(seededRuntimeObjects))
                continuation.finish()
            }
        }
    }
}
