import Foundation
import Testing
@testable import RuntimeViewerCore

@Suite("DyldUtilities.patchImagePathForDyld")
struct DyldUtilitiesTests {
    // MARK: - Identity cases

    @Test("returns input unchanged when DYLD_ROOT_PATH is nil")
    func returnsInputWhenNoRootPath() {
        let result = DyldUtilities.patchImagePathForDyld(
            "/usr/lib/libobjc.A.dylib", rootPath: nil)
        #expect(result == "/usr/lib/libobjc.A.dylib")
    }

    @Test("returns input unchanged for non-absolute path")
    func returnsInputForRelativePath() {
        let result = DyldUtilities.patchImagePathForDyld(
            "Foundation", rootPath: "/sim_root")
        #expect(result == "Foundation")
    }

    // MARK: - Patching

    @Test("prepends root path to absolute path")
    func prependsRootPath() {
        let result = DyldUtilities.patchImagePathForDyld(
            "/usr/lib/libobjc.A.dylib", rootPath: "/sim_root")
        #expect(result == "/sim_root/usr/lib/libobjc.A.dylib")
    }

    // MARK: - Idempotency

    @Test("calling twice produces the same result as calling once")
    func isIdempotent() {
        let raw = "/usr/lib/libobjc.A.dylib"
        let once = DyldUtilities.patchImagePathForDyld(raw, rootPath: "/sim_root")
        let twice = DyldUtilities.patchImagePathForDyld(once, rootPath: "/sim_root")
        #expect(twice == once)
        #expect(twice == "/sim_root/usr/lib/libobjc.A.dylib")
    }

    @Test("calling three times produces the same result as calling once")
    func isStableAcrossMultipleCalls() {
        let raw = "/usr/lib/libobjc.A.dylib"
        let once = DyldUtilities.patchImagePathForDyld(raw, rootPath: "/sim_root")
        let twice = DyldUtilities.patchImagePathForDyld(once, rootPath: "/sim_root")
        let thrice = DyldUtilities.patchImagePathForDyld(twice, rootPath: "/sim_root")
        #expect(thrice == once)
    }

    @Test("returns input unchanged when path equals root path itself")
    func returnsInputWhenPathEqualsRoot() {
        let result = DyldUtilities.patchImagePathForDyld(
            "/sim_root", rootPath: "/sim_root")
        #expect(result == "/sim_root")
    }

    // MARK: - Prefix precision

    @Test("does not mistake sibling prefix for already-patched")
    func distinguishesSimilarPrefix() {
        // `/sim_root_other` is NOT under `/sim_root`, even though it shares
        // the `/sim_root` prefix as a substring. Must be patched normally,
        // not treated as already-patched.
        let result = DyldUtilities.patchImagePathForDyld(
            "/sim_root_other/file", rootPath: "/sim_root")
        #expect(result == "/sim_root/sim_root_other/file")
    }
}

/// `imageNames().first` would silently return the wrong path under
/// `DYLD_INSERT_LIBRARIES` (e.g. Xcode injects `libLogRedirect.dylib` during
/// debug runs and it ends up at dyld image index 0, not the host executable).
/// `mainExecutablePath()` must use `_NSGetExecutablePath` so that
/// `@executable_path/...` rpath expansion stays correct in those scenarios.
@Suite("DyldUtilities.mainExecutablePath")
struct DyldUtilitiesMainExecutablePathTests {
    @Test("returns absolute path of running test process")
    func returnsAbsolutePath() {
        let path = DyldUtilities.mainExecutablePath()
        #expect(path.hasPrefix("/"), "expected absolute path, got: \(path)")
        #expect(!path.isEmpty)
        // The test runner exists on disk (no dyld_shared_cache games for the
        // main executable itself), so a vanilla file existence check applies.
        #expect(FileManager.default.fileExists(atPath: path),
                "test runner exe should exist on disk: \(path)")
    }
}
