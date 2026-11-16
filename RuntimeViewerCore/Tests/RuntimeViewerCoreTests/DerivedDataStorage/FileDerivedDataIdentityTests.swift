import Foundation
import Testing
import MachOKit
@testable import RuntimeViewerCore

/// Whose identity the derived data of an engine reading a file is kept under.
@Suite("File derived data identity")
struct FileDerivedDataIdentityTests {
    private static var hostCacheURL: URL? {
        FullDyldCache.host?.url
    }

    @Test("A cache read from disk is named by its platform, version and UUID, apart from any system")
    func fileCacheIdentity() throws {
        let cacheURL = try #require(Self.hostCacheURL)
        let summary = try RuntimeDyldSharedCacheSummary(contentsOf: cacheURL)

        let identity = try #require(RuntimeDerivedDataSystemIdentity.fileCache(summary))

        #expect(identity.isFileCache)
        #expect(identity.directoryName == "File-macOS-\(identity.operatingSystemVersion)-\(summary.uuid.uuidString)")
        #expect(RuntimeDerivedDataSystemIdentity.isFileCacheDirectory(named: identity.directoryName))
        // The cleanup reads no build out of it, so it never takes it for another system's.
        #expect(RuntimeDerivedDataSystemIdentity.operatingSystemBuild(ofDirectoryNamed: identity.directoryName) == nil)
    }

    @Test("A file's cache images are a cache's own, this Mac's when paired with it, and nobody's when read alone")
    func cacheImagesOfAFile() throws {
        let cacheURL = try #require(Self.hostCacheURL)
        let cache = try RuntimeFile(contentsOf: cacheURL)
        var executable = try RuntimeFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))

        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: cache)?.isFileCache == true)
        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: executable) == nil)
        executable.dependencyCache = .systemDyldSharedCache
        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: executable) == RuntimeDerivedDataSystemIdentity.current())
        executable.dependencyCache = .dyldSharedCache(cacheURL)
        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: executable)?.isFileCache == true)
    }

    @Test("Without the file service's switch, and outside an application, an engine reading a file keeps nothing")
    func fileStoreIsOffByDefault() throws {
        var executable = try RuntimeFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        executable.dependencyCache = .systemDyldSharedCache

        #expect(RuntimeDerivedData.fileStore(for: executable, isSharedCacheImage: { _ in true }) == nil)
    }
}
