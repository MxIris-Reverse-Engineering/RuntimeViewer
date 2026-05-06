import Combine
import Foundation
import Testing
@testable import RuntimeViewerCore

@Suite struct RuntimeEngineIndexStateTests {
    private static let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
    private static let coreText = "/System/Library/Frameworks/CoreText.framework/CoreText"

    @Test func isImageIndexedFalseForUnvisitedPath() async throws {
        let engine = RuntimeEngine(source: .local)
        let indexed = try await engine.isImageIndexed(path: "/never/seen")
        #expect(!indexed)
    }

    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: foundation),
            "Requires macOS with Foundation.framework present"
        )
    )
    func isImageIndexedTrueAfterLoadImage() async throws {
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImage(at: Self.foundation)
        let indexed = try await engine.isImageIndexed(path: Self.foundation)
        #expect(indexed)
    }

    /// Verifies the contract that `isImageIndexed` normalizes the input path the
    /// same way `loadImage(at:)` / `isImageLoaded(path:)` do, so callers don't
    /// see false negatives when they hand the engine an unpatched path.
    ///
    /// On most macOS hosts `DyldUtilities.patchImagePathForDyld` is a no-op for
    /// regular system framework paths (it only prepends `DYLD_ROOT_PATH` when
    /// that env var is set, e.g. inside a simulator runner). In that case the
    /// raw and patched forms are identical and this test still pins the
    /// contract: regression coverage triggers if the patcher's behavior ever
    /// changes such that the two forms diverge.
    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: foundation),
            "Requires macOS with Foundation.framework present"
        )
    )
    func isImageIndexedNormalizesPath() async throws {
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImage(at: Self.foundation)

        // After load, both raw and patched forms should report indexed.
        let patched = DyldUtilities.patchImagePathForDyld(Self.foundation)
        let indexedRaw = try await engine.isImageIndexed(path: Self.foundation)
        let indexedPatched = try await engine.isImageIndexed(path: patched)
        #expect(indexedRaw, "isImageIndexed must return true for the unpatched path")
        #expect(indexedPatched, "isImageIndexed must return true for the patched path too")
    }

    @Test func mainExecutablePathReturnsNonEmptyPath() async throws {
        // In the test runner this returns the runner's executable path, which
        // validates the "return dyld image 0" contract without requiring
        // RuntimeViewer.app to be running.
        let engine = RuntimeEngine(source: .local)
        let path = try await engine.mainExecutablePath()
        #expect(!path.isEmpty)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// Pins three contracts in one shot:
    /// 1. `loadImageForBackgroundIndexing` actually marks the image indexed.
    /// 2. It does NOT emit `reloadDataPublisher` (otherwise a depth-2+ BFS
    ///    would storm the sidebar with a refresh per visited image).
    /// 3. It does NOT emit `imageDidLoadPublisher` (otherwise the
    ///    background indexing coordinator's image-loaded pump would
    ///    recursively spawn a fresh batch for every image we just indexed).
    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: coreText),
            "Requires macOS with CoreText.framework present"
        )
    )
    func loadImageForBackgroundIndexingMarksIndexedAndDoesNotEmitPublishers() async throws {
        let engine = RuntimeEngine(source: .local)

        let counters = EmissionCounters()
        let imageLoadCancellable = engine.imageDidLoadPublisher.sink { _ in
            counters.incrementImageLoad()
        }
        let reloadDataCancellable = engine.reloadDataPublisher.sink { _ in
            counters.incrementReloadData()
        }
        defer {
            imageLoadCancellable.cancel()
            reloadDataCancellable.cancel()
        }

        try await engine.loadImageForBackgroundIndexing(at: Self.coreText)

        let indexed = try await engine.isImageIndexed(path: Self.coreText)
        #expect(indexed,
                "loadImageForBackgroundIndexing must populate the section caches")
        #expect(counters.imageLoadCount == 0,
                "loadImageForBackgroundIndexing must not emit imageDidLoadPublisher")
        #expect(counters.reloadDataCount == 0,
                "loadImageForBackgroundIndexing must not emit reloadDataPublisher")
    }

    /// Test-local thread-safe counter pair. PassthroughSubject delivers to
    /// `.sink` synchronously on whatever thread `.send` is called from, so
    /// the actor task driving `loadImageForBackgroundIndexing` and the test
    /// task can race on these counters.
    private final class EmissionCounters: @unchecked Sendable {
        private let lock = NSLock()
        private var imageLoad = 0
        private var reloadData = 0

        func incrementImageLoad() {
            lock.lock(); defer { lock.unlock() }
            imageLoad += 1
        }

        func incrementReloadData() {
            lock.lock(); defer { lock.unlock() }
            reloadData += 1
        }

        var imageLoadCount: Int {
            lock.lock(); defer { lock.unlock() }
            return imageLoad
        }

        var reloadDataCount: Int {
            lock.lock(); defer { lock.unlock() }
            return reloadData
        }
    }

    /// Pins the writer-side normalization contract: `loadImage(at:)` must
    /// canonicalize the path before inserting it into `loadedImagePaths`, so
    /// that downstream readers (which all canonicalize before lookup) hit.
    ///
    /// On most macOS hosts `patchImagePathForDyld` is identity, so this test
    /// passes trivially. It still pins the contract — if someone removes the
    /// writer-side patch or the patch starts diverging in some environment,
    /// this test catches the regression.
    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: foundation),
            "Requires macOS with Foundation.framework present"
        )
    )
    func loadImageInsertsCanonicalPathIntoLoadedImagePaths() async throws {
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImage(at: Self.foundation)

        let canonical = DyldUtilities.patchImagePathForDyld(Self.foundation)
        let loaded = await engine.loadedImagePaths
        #expect(
            loaded.contains(canonical),
            "loadImage must store the canonical (patched) form so reader-side lookups hit"
        )
    }

    /// Same contract as `loadImageInsertsCanonicalPathIntoLoadedImagePaths`,
    /// applied to the background indexing entry point.
    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: coreText),
            "Requires macOS with CoreText.framework present"
        )
    )
    func loadImageForBackgroundIndexingInsertsCanonicalPathIntoLoadedImagePaths()
        async throws
    {
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImageForBackgroundIndexing(at: Self.coreText)

        let canonical = DyldUtilities.patchImagePathForDyld(Self.coreText)
        let loaded = await engine.loadedImagePaths
        #expect(
            loaded.contains(canonical),
            "loadImageForBackgroundIndexing must store the canonical form"
        )
    }

    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: foundation),
            "Requires macOS with Foundation.framework present"
        )
    )
    func imageDidLoadPublisherFiresAfterLoadImage() async throws {
        let engine = RuntimeEngine(source: .local)

        // Buffer publisher emissions into an AsyncStream constructed *before*
        // we trigger loadImage, so the subscription is live by the time the
        // engine's PassthroughSubject sends.
        let stream = AsyncStream<String> { continuation in
            let cancellable = engine.imageDidLoadPublisher.sink { path in
                continuation.yield(path)
            }
            continuation.onTermination = { _ in cancellable.cancel() }
        }

        try await engine.loadImage(at: Self.foundation)

        var iterator = stream.makeAsyncIterator()
        let received = await iterator.next()
        #expect(received == Self.foundation)
    }
}
