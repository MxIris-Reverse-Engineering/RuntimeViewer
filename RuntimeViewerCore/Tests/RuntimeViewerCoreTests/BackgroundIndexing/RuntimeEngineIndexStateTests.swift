import XCTest
@testable import RuntimeViewerCore

final class RuntimeEngineIndexStateTests: XCTestCase {
    func test_isImageIndexed_falseForUnvisitedPath() async throws {
        let engine = RuntimeEngine(source: .local)
        let indexed = try await engine.isImageIndexed(path: "/never/seen")
        XCTAssertFalse(indexed)
    }

    func test_isImageIndexed_trueAfterLoadImage() async throws {
        let foundation = "/System/Library/Frameworks/Foundation.framework/Foundation"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: foundation),
            "Requires macOS with Foundation.framework present"
        )
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImage(at: foundation)
        let indexed = try await engine.isImageIndexed(path: foundation)
        XCTAssertTrue(indexed)
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
    func test_isImageIndexed_normalizesPath() async throws {
        let raw = "/System/Library/Frameworks/Foundation.framework/Foundation"
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: raw),
            "Requires macOS with Foundation.framework present"
        )
        let engine = RuntimeEngine(source: .local)
        try await engine.loadImage(at: raw)

        // After load, both raw and patched forms should report indexed.
        let patched = DyldUtilities.patchImagePathForDyld(raw)
        let indexedRaw = try await engine.isImageIndexed(path: raw)
        let indexedPatched = try await engine.isImageIndexed(path: patched)
        XCTAssertTrue(indexedRaw, "isImageIndexed must return true for the unpatched path")
        XCTAssertTrue(indexedPatched, "isImageIndexed must return true for the patched path too")
    }
}
