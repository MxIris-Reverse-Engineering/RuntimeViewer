import Foundation
import RuntimeViewerArchitectures
import RuntimeViewerCore
import Testing
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// Pins that a reload which ends without installing a new object list —
/// the `.loadError` and `.notLoaded` outcomes — still drops the list the
/// previous load published, rather than leaving its rows listed for an image
/// the reload gave up on. Only the success path assigns new nodes, so the
/// other outcomes have to clear them themselves.
///
/// This is also the only test in the target that drives a throwing reload
/// at all: with it absent, deleting the `.loadError` branch's work left the
/// whole suite green.
@Suite("Sidebar reload invalidation", .serialized)
@MainActor
struct SidebarReloadInvalidationTests {
    /// The view model subscribes to the shared local engine's data-change
    /// channel; its one-shot startup broadcast would otherwise land inside
    /// whichever test is running (see SharedLocalEngineTestLock.swift).
    init() async {
        await ensureSharedLocalEngineSettled()
    }

    @Test("a reload that fails drops the object list the previous load published")
    func failedReloadDropsThePreviousLoadsObjectList() async throws {
        try await withSharedLocalEngineLock {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let viewModel = FailableSeededListViewModel(
                seededRuntimeObjects: Self.makeSeededRuntimeObjects(),
                imageNode: try await makeLoadedImageNode(),
                documentState: DocumentState(),
                router: router
            )

            let loaded = try await pollUntil(timeout: .seconds(30)) {
                viewModel.loadState == .loaded && !viewModel.nodes.isEmpty
            }
            #expect(loaded, "the seeded reload never published its objects; state=\(viewModel.loadState)")

            viewModel.failNextReload()
            viewModel.scheduleReload()
            let failed = try await pollUntil(timeout: .seconds(30)) {
                if case .loadError = viewModel.loadState { return true }
                return false
            }
            #expect(failed, "the reload never reached .loadError; state=\(viewModel.loadState)")
            #expect(
                viewModel.nodes.isEmpty,
                "the failed reload left the previous load's rows in place"
            )
        }
    }

    @Test("a reload that finds the image unloaded drops the object list the previous load published")
    func notLoadedReloadDropsThePreviousLoadsObjectList() async throws {
        try await withSharedLocalEngineLock {
            let router = MockRouter<SidebarRuntimeObjectRoute>()
            let viewModel = FailableSeededListViewModel(
                seededRuntimeObjects: Self.makeSeededRuntimeObjects(),
                imageNode: try await makeLoadedImageNode(),
                documentState: DocumentState(),
                router: router
            )

            let loaded = try await pollUntil(timeout: .seconds(30)) {
                viewModel.loadState == .loaded && !viewModel.nodes.isEmpty
            }
            #expect(loaded, "the seeded reload never published its objects; state=\(viewModel.loadState)")

            viewModel.reportImageUnloadedFromNextReload()
            viewModel.scheduleReload()
            let unloaded = try await pollUntil(timeout: .seconds(30)) {
                viewModel.loadState == .notLoaded
            }
            #expect(unloaded, "the reload never reached .notLoaded; state=\(viewModel.loadState)")
            #expect(
                viewModel.nodes.isEmpty,
                "the reload that found the image unloaded left the previous load's rows in place"
            )
        }
    }

    private static func makeSeededRuntimeObjects() -> [RuntimeObject] {
        (0 ..< 32).map { index in
            RuntimeObject(
                name: "SeededType\(index)",
                displayName: "SeededType\(index)",
                kind: .swift(.type(.class)),
                imagePath: "/System/Library/Frameworks/TestFramework.framework/TestFramework",
                children: [],
                properties: []
            )
        }
    }
}

/// Serves a seeded object list until `failNextReload()` is called, then
/// finishes the stream with an error so `scheduleReload()`'s generic
/// `catch` — the `.loadError` outcome — runs; or, after
/// `reportImageUnloadedFromNextReload()`, reports the image unloaded so the
/// reload takes the `.notLoaded` outcome.
private final class FailableSeededListViewModel: SidebarRuntimeObjectListViewModel {
    private enum ReloadFailure: Error {
        case injected
    }

    private let seededRuntimeObjects: [RuntimeObject]
    private var shouldFailNextReload = false
    private var reportsImageUnloaded = false

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

    func reportImageUnloadedFromNextReload() {
        reportsImageUnloaded = true
    }

    override func isImageLoaded() async throws -> Bool {
        if reportsImageUnloaded {
            return false
        }
        return try await super.isImageLoaded()
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
