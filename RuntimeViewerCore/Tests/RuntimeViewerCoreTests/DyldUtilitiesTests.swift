import Foundation
import Testing
import MachOKit
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

/// Guards against regressing the Debug-stub redirect documented on
/// `DyldUtilities.machOImage(forPath:)`. The dependency count is the smoking
/// gun: a Debug stub links only `@rpath/<name>.debug.dylib` +
/// `/usr/lib/libSystem.B.dylib`, while the real `.debug.dylib` pulls in
/// XCTest, Foundation, and the rest of the test runtime — historically
/// dozens of entries.
///
/// Note: CLI `swift test` runs against `swiftpm-testing-helper`, which is a
/// single-binary Release-style runner with no sibling `.debug.dylib`. The
/// assertion is meaningful only when invoked via `xcodebuild test` (or from
/// inside Xcode), where the test bundle's host *is* a Debug stub. Outside
/// that environment the test silently no-ops rather than fail spuriously.
@Suite("DyldUtilities.machOImage(forPath:) for the main executable")
struct DyldUtilitiesMachOImageMainExecutableTests {
    @Test("redirects Debug stub to the sibling .debug.dylib when present")
    func redirectsDebugStub() throws {
        let mainPath = DyldUtilities.mainExecutablePath()
        let debugDylibPath = mainPath + ".debug.dylib"

        // Skip on Release-style runners (e.g. swiftpm-testing-helper).
        guard FileManager.default.fileExists(atPath: debugDylibPath) else { return }

        let image = try #require(DyldUtilities.machOImage(forPath: mainPath),
                                 "machOImage(forPath:) returned nil for the host main executable")

        // Stub has 2 LC_LOAD_DYLIB entries; the real .debug.dylib has many.
        // Pin the lower bound generously so we only fail when the regression
        // (returning the stub) actually reappears.
        let dependencyCount = Array(image.dependencies).count
        #expect(dependencyCount > 5,
                "expected redirect to .debug.dylib (lots of dependencies), got the stub instead (\(dependencyCount) deps)")
    }
}
