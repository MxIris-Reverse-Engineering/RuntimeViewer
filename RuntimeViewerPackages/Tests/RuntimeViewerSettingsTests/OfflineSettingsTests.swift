import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerSettings

/// Which dyld shared cache a file read offline is paired with when the user
/// has not picked one.
@Suite("Offline dependency cache selection")
struct OfflineSettingsTests {
    private static func file(platform: String?, version: String = "27.0", content: RuntimeOfflineFile.Content = .machO(slice: nil)) -> RuntimeOfflineFile {
        RuntimeOfflineFile(
            url: URL(fileURLWithPath: "/tmp/Foo.framework"),
            content: content,
            platform: platform.map { RuntimeOfflineFile.Platform(name: $0, version: version) },
            displayName: "Foo.framework"
        )
    }

    private static func cache(_ platformName: String, _ version: String) -> Settings.Offline.DependencyCache {
        Settings.Offline.DependencyCache(
            path: "/Caches/\(platformName)-\(version)/dyld_shared_cache_arm64e",
            platformName: platformName,
            version: version,
            architecture: "arm64e",
            uuid: UUID().uuidString
        )
    }

    private static func path(of choice: RuntimeOfflineFile.DependencyCache?) -> String? {
        guard case .dyldSharedCache(let url) = choice else { return nil }
        return url.path
    }

    @Test("A file built for macOS or Mac Catalyst reads this Mac's cache, registered caches or not")
    func macFilesPairWithThisMac() {
        let offline = Settings.Offline(dependencyCaches: [Self.cache("iOS", "27.0")])

        #expect(offline.defaultDependencyCache(for: Self.file(platform: "macOS")) == .systemDyldSharedCache)
        #expect(offline.defaultDependencyCache(for: Self.file(platform: "macCatalyst")) == .systemDyldSharedCache)
    }

    @Test("Among the platform's caches, the oldest one no older than the file's SDK is picked")
    func oldestCacheNoOlderThanTheSDK() {
        let offline = Settings.Offline(dependencyCaches: [Self.cache("iOS", "27.0"), Self.cache("iOS", "26"), Self.cache("iOS", "26.4")])

        #expect(Self.path(of: offline.defaultDependencyCache(for: Self.file(platform: "iOS", version: "26.2"))) == Self.cache("iOS", "26.4").path)
        #expect(Self.path(of: offline.defaultDependencyCache(for: Self.file(platform: "iOS", version: "26.0"))) == Self.cache("iOS", "26").path)
    }

    @Test("When every cache of the platform is older than the file's SDK, the newest is picked")
    func newestWhenAllAreOlder() {
        let offline = Settings.Offline(dependencyCaches: [Self.cache("iOS", "26.0"), Self.cache("iOS", "27.0")])

        #expect(Self.path(of: offline.defaultDependencyCache(for: Self.file(platform: "iOS", version: "28.0"))) == Self.cache("iOS", "27.0").path)
    }

    @Test("A simulator's file pairs only with that simulator's caches")
    func simulatorFilesPairWithSimulatorCaches() {
        let deviceOnly = Settings.Offline(dependencyCaches: [Self.cache("iOS", "27.0")])
        let withSimulator = Settings.Offline(dependencyCaches: [Self.cache("iOS", "27.0"), Self.cache("iOSSimulator", "27.0")])

        #expect(deviceOnly.defaultDependencyCache(for: Self.file(platform: "iOSSimulator")) == nil)
        #expect(Self.path(of: withSimulator.defaultDependencyCache(for: Self.file(platform: "iOSSimulator"))) == Self.cache("iOSSimulator", "27.0").path)
    }

    @Test("A cache, a file of another platform with nothing registered, or a file that names no platform reads alone")
    func otherwiseTheFileReadsAlone() {
        let offline = Settings.Offline(dependencyCaches: [Self.cache("iOS", "27.0")])

        #expect(offline.defaultDependencyCache(for: Self.file(platform: "iOS", content: .dyldSharedCache)) == nil)
        #expect(offline.defaultDependencyCache(for: Self.file(platform: "tvOS")) == nil)
        #expect(offline.defaultDependencyCache(for: Self.file(platform: nil)) == nil)
    }
}
