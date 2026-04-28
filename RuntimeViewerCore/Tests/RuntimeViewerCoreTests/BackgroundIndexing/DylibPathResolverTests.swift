import XCTest
@testable import RuntimeViewerCore

final class DylibPathResolverTests: XCTestCase {
    private let resolver = DylibPathResolver()

    func test_absolutePath_returnsAsIsWhenExists() throws {
        // Use /usr/lib/dyld because most "dylibs" live in the dyld shared cache
        // and have no on-disk file on Apple Silicon Macs (e.g. libSystem.B.dylib).
        // /usr/lib/dyld is a real on-disk file across macOS versions.
        let path = "/usr/lib/dyld"
        XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                      "precondition: /usr/lib/dyld exists in this test env")
        XCTAssertEqual(
            resolver.resolve(installName: path,
                             imagePath: "/any", rpaths: [],
                             mainExecutablePath: "/any"),
            path
        )
    }

    func test_absolutePath_returnsNilWhenMissing() {
        XCTAssertNil(resolver.resolve(installName: "/nonexistent/Foo.dylib",
                                      imagePath: "/any", rpaths: [],
                                      mainExecutablePath: "/any"))
    }

    func test_absolutePath_acceptsDyldSharedCachePath() throws {
        // System frameworks live in the dyld shared cache and have no on-disk
        // file on Apple Silicon. The resolver must accept them anyway,
        // otherwise BFS marks every UIKit/Foundation dependency as
        // "path unresolved" and the toolbar floods with red ✗ rows.
        //
        // Try a handful of well-known cache residents — pick the first one
        // this host's cache reports membership for. Empty `picked` means
        // the test process couldn't load DyldCacheLoaded.current at all
        // (sandboxed test runners on some CI configs), in which case skip.
        let candidates = [
            "/System/Library/Frameworks/Foundation.framework/Foundation",
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
            "/usr/lib/libobjc.A.dylib",
            "/usr/lib/libSystem.B.dylib",
        ]
        let picked = candidates.first(where: DyldUtilities.isInDyldSharedCache)
        try XCTSkipUnless(
            picked != nil,
            "no candidate found in this host's dyld shared cache (test env may lack cache access)"
        )
        let candidate = picked!
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: candidate),
            "precondition: \(candidate) should NOT exist on disk on this host"
        )
        XCTAssertEqual(
            resolver.resolve(installName: candidate,
                             imagePath: "/any", rpaths: [],
                             mainExecutablePath: "/any"),
            candidate
        )
    }

    func test_executablePath_substitutesMainExecutableDir() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let exePath = tempDir + "/FakeExe"
        let frameworkPath = tempDir + "/Foo"
        try "".write(toFile: exePath, atomically: true, encoding: .utf8)
        try "".write(toFile: frameworkPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: exePath)
            try? FileManager.default.removeItem(atPath: frameworkPath)
        }
        let resolved = resolver.resolve(
            installName: "@executable_path/Foo",
            imagePath: "/any", rpaths: [],
            mainExecutablePath: exePath)
        XCTAssertEqual(resolved, frameworkPath)
    }

    func test_loaderPath_substitutesImageDir() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let imagePath = tempDir + "/FakeLib"
        let siblingPath = tempDir + "/Sibling"
        try "".write(toFile: imagePath, atomically: true, encoding: .utf8)
        try "".write(toFile: siblingPath, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: imagePath)
            try? FileManager.default.removeItem(atPath: siblingPath)
        }
        let resolved = resolver.resolve(
            installName: "@loader_path/Sibling",
            imagePath: imagePath, rpaths: [],
            mainExecutablePath: "/any")
        XCTAssertEqual(resolved, siblingPath)
    }

    func test_rpath_usesFirstMatchingRpath() throws {
        let tempDir = FileManager.default.temporaryDirectory.path
        let rpath1 = tempDir + "/DoesNotExist"
        let rpath2 = tempDir + "/RPath2"
        try? FileManager.default.createDirectory(atPath: rpath2,
                                                 withIntermediateDirectories: true)
        let target = rpath2 + "/MyLib"
        try "".write(toFile: target, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(atPath: target)
            try? FileManager.default.removeItem(atPath: rpath2)
        }
        let resolved = resolver.resolve(
            installName: "@rpath/MyLib",
            imagePath: "/any", rpaths: [rpath1, rpath2],
            mainExecutablePath: "/any")
        XCTAssertEqual(resolved, target)
    }

    func test_rpath_returnsNilWhenNoMatch() {
        XCTAssertNil(resolver.resolve(
            installName: "@rpath/Missing",
            imagePath: "/any", rpaths: ["/nope1", "/nope2"],
            mainExecutablePath: "/any"))
    }
}
