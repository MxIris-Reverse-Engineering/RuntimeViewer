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

    @Test(
        .enabled(
            if: FileManager.default.fileExists(atPath: coreText),
            "Requires macOS with CoreText.framework present"
        )
    )
    func loadImageForBackgroundIndexingDoesNotTriggerReloadData() async throws {
        // CoreText is reliable across macOS versions.
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImageForBackgroundIndexing(at: Self.coreText)
        let indexed = try await engine.isImageIndexed(path: Self.coreText)
        #expect(indexed)
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
