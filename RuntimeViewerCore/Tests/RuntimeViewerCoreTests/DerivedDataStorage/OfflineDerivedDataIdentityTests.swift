import Foundation
import Testing
import MachOKit
@testable import RuntimeViewerCore

/// Whose identity the derived data of an engine reading a file is kept under.
@Suite("Offline derived data identity")
struct OfflineDerivedDataIdentityTests {
    private static var hostCacheURL: URL? {
        FullDyldCache.host?.url
    }

    @Test("A cache read from disk is named by its platform, version and UUID, apart from any system")
    func offlineCacheIdentity() throws {
        let cacheURL = try #require(Self.hostCacheURL)
        let summary = try RuntimeDyldSharedCacheSummary(contentsOf: cacheURL)

        let identity = try #require(RuntimeDerivedDataSystemIdentity.offlineCache(summary))

        #expect(identity.isOfflineCache)
        #expect(identity.directoryName == "Offline-macOS-\(identity.operatingSystemVersion)-\(summary.uuid.uuidString)")
        #expect(RuntimeDerivedDataSystemIdentity.isOfflineCacheDirectory(named: identity.directoryName))
        // The cleanup reads no build out of it, so it never takes it for another system's.
        #expect(RuntimeDerivedDataSystemIdentity.operatingSystemBuild(ofDirectoryNamed: identity.directoryName) == nil)
    }

    @Test("A file's cache images are a cache's own, this Mac's when paired with it, and nobody's when read alone")
    func cacheImagesOfAFile() throws {
        let cacheURL = try #require(Self.hostCacheURL)
        let cache = try RuntimeOfflineFile(contentsOf: cacheURL)
        var executable = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))

        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: cache)?.isOfflineCache == true)
        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: executable) == nil)
        executable.dependencyCache = .systemDyldSharedCache
        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: executable) == RuntimeDerivedDataSystemIdentity.current())
        executable.dependencyCache = .dyldSharedCache(cacheURL)
        #expect(RuntimeDerivedData.systemIdentity(forCacheImagesOf: executable)?.isOfflineCache == true)
    }

    @Test("Without the offline service's switch, and outside an application, an engine reading a file keeps nothing")
    func offlineStoreIsOffByDefault() throws {
        var executable = try RuntimeOfflineFile(contentsOf: URL(fileURLWithPath: "/usr/bin/true"))
        executable.dependencyCache = .systemDyldSharedCache

        #expect(RuntimeDerivedData.offlineStore(for: executable, isSharedCacheImage: { _ in true }) == nil)
    }
}
