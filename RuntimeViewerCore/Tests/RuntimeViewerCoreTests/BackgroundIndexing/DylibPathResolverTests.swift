import Foundation
import Testing
@testable import RuntimeViewerCore

@Suite struct DylibPathResolverTests {
    private let resolver = DylibPathResolver()

    /// Candidates probed by `absolutePathAcceptsDyldSharedCachePath`. Lifted
    /// out so the `.enabled(if:)` trait can reuse it as a registration-time
    /// gate (no candidate in cache → skip the test on this host).
    private static let dyldSharedCacheCandidates = [
        "/System/Library/Frameworks/Foundation.framework/Foundation",
        "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation",
        "/usr/lib/libobjc.A.dylib",
        "/usr/lib/libSystem.B.dylib",
    ]

    @Test func absolutePathReturnsAsIsWhenExists() {
        // Use /usr/lib/dyld because most "dylibs" live in the dyld shared cache
        // and have no on-disk file on Apple Silicon Macs (e.g. libSystem.B.dylib).
        // /usr/lib/dyld is a real on-disk file across macOS versions.
        let path = "/usr/lib/dyld"
        #expect(FileManager.default.fileExists(atPath: path),
                "precondition: /usr/lib/dyld exists in this test env")
        #expect(resolver.resolve(installName: path,
                                 imagePath: "/any", rpaths: [],
                                 mainExecutablePath: "/any") == path)
    }

    @Test func absolutePathReturnsNilWhenMissing() {
        #expect(resolver.resolve(installName: "/nonexistent/Foo.dylib",
                                 imagePath: "/any", rpaths: [],
                                 mainExecutablePath: "/any") == nil)
    }

    @Test(
        .enabled(
            if: dyldSharedCacheCandidates.contains(where: DyldUtilities.isInDyldSharedCache),
            "no candidate in dyld shared cache (test env may lack cache access)"
        )
    )
    func absolutePathAcceptsDyldSharedCachePath() throws {
        // System frameworks live in the dyld shared cache and have no on-disk
        // file on Apple Silicon. The resolver must accept them anyway,
        // otherwise BFS marks every UIKit/Foundation dependency as
        // "path unresolved" and the toolbar floods with red ✗ rows.
        let candidate = try #require(
            Self.dyldSharedCacheCandidates.first(where: DyldUtilities.isInDyldSharedCache)
        )
        #expect(!FileManager.default.fileExists(atPath: candidate),
                "precondition: \(candidate) should NOT exist on disk on this host")
        #expect(resolver.resolve(installName: candidate,
                                 imagePath: "/any", rpaths: [],
                                 mainExecutablePath: "/any") == candidate)
    }

    @Test func executablePathSubstitutesMainExecutableDir() throws {
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
        #expect(resolved == frameworkPath)
    }

    @Test func loaderPathSubstitutesImageDir() throws {
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
        #expect(resolved == siblingPath)
    }

    @Test func rpathUsesFirstMatchingRpath() throws {
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
        #expect(resolved == target)
    }

    @Test func rpathReturnsNilWhenNoMatch() {
        #expect(resolver.resolve(
            installName: "@rpath/Missing",
            imagePath: "/any", rpaths: ["/nope1", "/nope2"],
            mainExecutablePath: "/any") == nil)
    }
}
