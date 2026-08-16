import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerApplication

/// Regression suite for the residual costs lazy materialization still
/// carried after PR #88's rewrite.
///
/// - The materialized-row memo was unbounded and cleared only by a reload.
///   `.fuzzySearch` keeps every non-zero-score haystack, and a haystack is
///   the object's name plus every descendant's, so a one- or two-character
///   query matched essentially the whole image and the apply loop built a
///   cell view model (and, recursively, one per descendant) for every row
///   in a single main-actor turn — reintroducing the O(N) main-thread cost
///   the lazy path exists to remove, and retaining all of it for the
///   document's life.
/// - A superseded pass threw away a completed haystack build. The
///   haystacks depend only on the object list, never on the query, so
///   whenever the build outran the 150 ms debounce, continuous typing
///   discarded a full build per query and the cache never populated.
/// - Stamping a highlight on a freshly materialized cell rebuilt, on the
///   main actor, the byte-identical twin of the haystack the off-main pass
///   was still holding.
@Suite("OpenQuicklyMaterializationBounds", .serialized)
@MainActor
struct OpenQuicklyMaterializationBoundsTests {
    private static let seededObjectCount = 1_200

    @Test("a query matching every row materializes at most the row cap")
    func wideQueryStopsAtTheRowCap() async throws {
        try await withSharedLocalEngineLock {
            let harness = try await Harness(objectCount: Self.seededObjectCount)

            // Matches every seeded object, which is the shape a one- or
            // two-character query has against a real image.
            harness.search("Type")

            let applied = try await pollUntil(timeout: .seconds(20)) {
                !harness.viewModel.filteredNodesForOpenQuickly.isEmpty
            }
            #expect(applied, "the wide query never produced any rows")

            let cap = SidebarRuntimeObjectListViewModel.openQuicklyMaximumMaterializedRows
            #expect(Self.seededObjectCount > cap, "the fixture must exceed the cap for this to mean anything")
            #expect(harness.viewModel.filteredNodesForOpenQuickly.count == cap)
            #expect(
                harness.viewModel.openQuicklyCellViewModelsByRowIndex.count == cap,
                "every displayed row is materialized and nothing beyond the cap is"
            )
            #expect(harness.viewModel.filteredNodesForOpenQuickly.allSatisfy { $0.filterResult != nil })
        }
    }

    /// Two contracts in one timeline, both about a build that belongs to
    /// the object list rather than to any one query:
    ///
    /// 1. Overlapping passes share it. Sampling the cache at schedule time
    ///    and never re-reading it made every keystroke landing during the
    ///    first build start its own full O(N) build of the identical array,
    ///    and `defaultHaystackBuilder` has no cancellation points, so
    ///    cancelling the superseded pass freed nothing — the builds simply
    ///    ran concurrently.
    /// 2. A superseded pass's completed build is still installed. Discarding
    ///    it meant that whenever the build outran the debounce, continuous
    ///    typing threw away a complete build per query and the cache was
    ///    never populated at all.
    @Test("overlapping passes share one haystack build, and its result is installed")
    func overlappingPassesShareOneHaystackBuild() async throws {
        try await withSharedLocalEngineLock {
            let gate = HaystackBuildGate()
            let harness = try await Harness(objectCount: 64, gate: gate)

            harness.search("Alpha")
            let firstBuildStarted = try await pollUntil(timeout: .seconds(20)) { gate.startedBuildCount == 1 }
            #expect(firstBuildStarted, "the first query never started a haystack build")

            // Supersedes the first pass while its build is still gated. Give
            // it its full debounce window plus margin — a pass that were
            // going to start its own build would have done so by now.
            harness.search("Alphab")
            try await Task.sleep(for: .milliseconds(600))
            #expect(
                gate.startedBuildCount == 1,
                "the second query started a redundant build instead of joining the one in flight"
            )

            // Releasing the single shared build must populate the cache even
            // though the pass that started it was cancelled and
            // out-generationed.
            gate.releaseNext()

            let cachePopulated = try await pollUntil(timeout: .seconds(20)) {
                harness.viewModel.openQuicklyHaystacksCache != nil
            }
            #expect(
                cachePopulated,
                "the shared build's result was discarded with the pass that started it"
            )

            gate.release()
        }
    }

    /// The cap may only drop rows that are *less relevant*, and fuzzy
    /// weight alone cannot tell it which those are.
    ///
    /// `FuzzySearchable.fuzzyMatch` stops accumulating once the pattern is
    /// consumed, so every haystack containing the query as one contiguous
    /// run scores the same constant. Here 600 filler objects match only
    /// because a *descendant* is named `Alpha`, and one object matches in
    /// its own name — all 601 tie. `nodes` is name-sorted, so the filler
    /// block occupies the first 600 rows and a weight-ordered
    /// `prefix(500)` drops the only row the user could have meant.
    @Test("the row cap keeps the most relevant matches, not the first ones in the tie")
    func rowCapKeepsTheMostRelevantMatches() async throws {
        try await withSharedLocalEngineLock {
            // Filler names share no character with the query, so each
            // haystack carries exactly one matched run — the child's name —
            // and every verdict lands on the same weight.
            let fillerObjects = (0 ..< 600).map { index in
                Harness.makeRuntimeObject(
                    displayName: String(format: "Zx%04d", index),
                    children: [Harness.makeRuntimeObject(displayName: "Alpha")]
                )
            }
            // Matches at the same offset as the target and carries a shorter
            // name, so weight, match position and name length between them
            // all either tie or favour this one. Only "the hit is inside the
            // object's own name" separates them — without that key this row
            // takes first place and the last assertion fails.
            let decoyObject = Harness.makeRuntimeObject(
                displayName: "Zz",
                children: [Harness.makeRuntimeObject(displayName: "Alpha")]
            )
            // Sorts after every filler by name, and matches in its own name
            // rather than in a descendant's.
            let targetObject = Harness.makeRuntimeObject(displayName: "zzzAlpha")
            let harness = try await Harness(
                seededRuntimeObjects: fillerObjects + [decoyObject, targetObject]
            )

            harness.search("Alpha")

            let applied = try await pollUntil(timeout: .seconds(20)) {
                !harness.viewModel.filteredNodesForOpenQuickly.isEmpty
            }
            #expect(applied, "the query never produced any rows")

            let cap = SidebarRuntimeObjectListViewModel.openQuicklyMaximumMaterializedRows
            let displayedNames = harness.viewModel.filteredNodesForOpenQuickly.map(\.runtimeObject.displayName)
            #expect(
                displayedNames.count == cap,
                "the fixture must overflow the cap for this to mean anything"
            )
            #expect(
                displayedNames.contains(targetObject.displayName),
                "the cap dropped a row that scores exactly as high as the 500 it kept"
            )
            #expect(
                displayedNames.first == targetObject.displayName,
                "a hit in the object's own name must outrank hits that only landed in a descendant's"
            )
        }
    }
}

// MARK: - Harness

extension OpenQuicklyMaterializationBoundsTests {
    /// Gates every haystack build so a test can hold one open across a
    /// supersession.
    fileprivate final class HaystackBuildGate: @unchecked Sendable {
        private let lock = NSLock()
        private var isOpen = false
        private var pendingContinuations: [CheckedContinuation<Void, Never>] = []
        private var startedBuilds = 0

        var startedBuildCount: Int { lock.withLock { startedBuilds } }

        func waitForRelease() async {
            await withCheckedContinuation { continuation in
                let shouldResumeImmediately = lock.withLock {
                    startedBuilds += 1
                    if isOpen { return true }
                    pendingContinuations.append(continuation)
                    return false
                }
                if shouldResumeImmediately {
                    continuation.resume()
                }
            }
        }

        /// Resumes only the earliest gated build, leaving later ones held.
        /// The superseded-pass test needs this: releasing everything would
        /// let the *current* pass finish and install the cache itself,
        /// which the old always-discard code also did — the assertion
        /// only pins the fix if the superseded build is the sole finisher.
        func releaseNext() {
            let continuationToResume = lock.withLock {
                pendingContinuations.isEmpty ? nil : pendingContinuations.removeFirst()
            }
            continuationToResume?.resume()
        }

        func release() {
            let continuationsToResume = lock.withLock {
                isOpen = true
                let pending = pendingContinuations
                pendingContinuations = []
                return pending
            }
            continuationsToResume.forEach { $0.resume() }
        }
    }

    @MainActor
    fileprivate struct Harness {
        let viewModel: SidebarRuntimeObjectListViewModel

        private let searchStringRelay = PublishRelay<String>()
        private let router: MockRouter<SidebarRuntimeObjectRoute>

        init(
            objectCount: Int,
            gate: HaystackBuildGate? = nil
        ) async throws {
            try await self.init(
                seededRuntimeObjects: Self.makeRuntimeObjects(count: objectCount),
                gate: gate
            )
        }

        init(
            seededRuntimeObjects: [RuntimeObject],
            gate: HaystackBuildGate? = nil
        ) async throws {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let builder: SidebarRuntimeObjectListViewModel.HaystackBuilder = { runtimeObjects in
                if let gate {
                    await gate.waitForRelease()
                }
                return runtimeObjects.map { SidebarRuntimeObjectCellViewModel.haystack(for: $0) }
            }
            let imageNode = try await Self.makeImageNode()
            let documentState = DocumentState()
            let viewModel = SeededListViewModel(
                seededRuntimeObjects: seededRuntimeObjects,
                imageNode: imageNode,
                documentState: documentState,
                router: router,
                haystackBuilder: builder
            )
            self.router = router
            self.viewModel = viewModel

            let reloadFinished = try await pollUntil(timeout: .seconds(30)) {
                viewModel.loadState == .loaded
            }
            #expect(reloadFinished, "seeded reload never reached .loaded; state=\(viewModel.loadState)")

            let input = SidebarRuntimeObjectListViewModel.Input(
                runtimeObjectClickedForOpenQuickly: .never(),
                searchStringForOpenQuickly: searchStringRelay.asSignal(),
                addBookmark: .never()
            )
            _ = viewModel.transform(input)
            // The input stream drops its first element (the search field's
            // initial value in the real UI), so prime it before querying.
            searchStringRelay.accept("")
        }

        func search(_ query: String) {
            searchStringRelay.accept(query)
        }

        /// The reload path resolves its objects through a real image node,
        /// so the fixture borrows a leaf node from the shared local
        /// engine's image list the way `OpenQuicklyLazyConstructionTests`
        /// does. Only the node's shape matters — `buildRuntimeObjects()` is
        /// overridden to return the seeded array.
        private static func makeImageNode() async throws -> RuntimeImageNode {
            let localRuntimeEngine = RuntimeEngine.local
            var imageList: [String] = []
            let engineReady = try await pollUntil(timeout: .seconds(15)) {
                imageList = await localRuntimeEngine.imageList
                return !imageList.isEmpty
            }
            #expect(engineReady, "local engine never published an image list")
            let imagePath = try #require(imageList.first { $0.hasSuffix("/Foundation") } ?? imageList.first)

            let rootImageNode = RuntimeImageNode.rootNode(for: [imagePath], name: "Root")
            var leafImageNode = rootImageNode
            while let firstChild = leafImageNode.children.first {
                leafImageNode = firstChild
            }
            // `parent` links are weak and `absolutePath` derives from them
            // lazily. Materialize it while the root still owns the ancestor
            // chain — hand back a bare leaf instead and the chain deallocates
            // behind it, collapsing `path` to "/" and pinning the view model
            // at `.notLoaded` (`isImageLoaded("/")` is never true).
            withExtendedLifetime(rootImageNode) {
                _ = leafImageNode.absolutePath
            }
            return leafImageNode
        }

        private static func makeRuntimeObjects(count: Int) -> [RuntimeObject] {
            (0 ..< count).map { index in
                makeRuntimeObject(displayName: "TestFramework.AlphabetGeneratedType\(index)")
            }
        }

        static func makeRuntimeObject(displayName: String, children: [RuntimeObject] = []) -> RuntimeObject {
            RuntimeObject(
                name: displayName,
                displayName: displayName,
                kind: .swift(.type(.class)),
                secondaryKind: nil,
                imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
                children: children,
                properties: []
            )
        }
    }
}

private final class SeededListViewModel: SidebarRuntimeObjectListViewModel {
    private let seededRuntimeObjects: [RuntimeObject]

    init(
        seededRuntimeObjects: [RuntimeObject],
        imageNode: RuntimeImageNode,
        documentState: DocumentState,
        router: any Router<SidebarRuntimeObjectRoute>,
        haystackBuilder: @escaping SidebarRuntimeObjectListViewModel.HaystackBuilder
    ) {
        self.seededRuntimeObjects = seededRuntimeObjects
        super.init(
            imageNode: imageNode,
            documentState: documentState,
            router: router,
            haystackBuilder: haystackBuilder
        )
    }

    override func buildRuntimeObjects() async throws -> [RuntimeObject] {
        seededRuntimeObjects
    }

    override func buildRuntimeObjectsStream() -> AsyncThrowingStream<RuntimeObjectsLoadingEvent, Error> {
        AsyncThrowingStream { [seededRuntimeObjects] continuation in
            continuation.yield(.completed(seededRuntimeObjects))
            continuation.finish()
        }
    }
}
