import Foundation
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerSettings

/// Which dyld shared cache a file is paired with when the user
/// has not picked one.
@Suite("File dependency cache selection")
struct FileSettingsTests {
    private static func file(platform: String?, version: String = "27.0", content: RuntimeFile.Content = .machO(slice: nil)) -> RuntimeFile {
        RuntimeFile(
            url: URL(fileURLWithPath: "/tmp/Foo.framework"),
            content: content,
            platform: platform.map { RuntimeFile.Platform(name: $0, version: version) },
            displayName: "Foo.framework"
        )
    }

    private static func cache(_ platformName: String, _ version: String) -> Settings.File.DependencyCache {
        Settings.File.DependencyCache(
            path: "/Caches/\(platformName)-\(version)/dyld_shared_cache_arm64e",
            platformName: platformName,
            version: version,
            architecture: "arm64e",
            uuid: UUID().uuidString
        )
    }

    private static func path(of choice: RuntimeFile.DependencyCache?) -> String? {
        guard case .dyldSharedCache(let url) = choice else { return nil }
        return url.path
    }

    @Test("A file built for macOS or Mac Catalyst reads this Mac's cache, registered caches or not")
    func macFilesPairWithThisMac() {
        let fileSettings = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0")])

        #expect(fileSettings.defaultDependencyCache(for: Self.file(platform: "macOS")) == .systemDyldSharedCache)
        #expect(fileSettings.defaultDependencyCache(for: Self.file(platform: "macCatalyst")) == .systemDyldSharedCache)
    }

    @Test("Among the platform's caches, the oldest one no older than the file's SDK is picked")
    func oldestCacheNoOlderThanTheSDK() {
        let fileSettings = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0"), Self.cache("iOS", "26"), Self.cache("iOS", "26.4")])

        #expect(Self.path(of: fileSettings.defaultDependencyCache(for: Self.file(platform: "iOS", version: "26.2"))) == Self.cache("iOS", "26.4").path)
        #expect(Self.path(of: fileSettings.defaultDependencyCache(for: Self.file(platform: "iOS", version: "26.0"))) == Self.cache("iOS", "26").path)
    }

    @Test("When every cache of the platform is older than the file's SDK, the newest is picked")
    func newestWhenAllAreOlder() {
        let fileSettings = Settings.File(dependencyCaches: [Self.cache("iOS", "26.0"), Self.cache("iOS", "27.0")])

        #expect(Self.path(of: fileSettings.defaultDependencyCache(for: Self.file(platform: "iOS", version: "28.0"))) == Self.cache("iOS", "27.0").path)
    }

    @Test("A simulator's file pairs only with that simulator's caches")
    func simulatorFilesPairWithSimulatorCaches() {
        let deviceOnly = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0")])
        let withSimulator = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0"), Self.cache("iOSSimulator", "27.0")])

        #expect(deviceOnly.defaultDependencyCache(for: Self.file(platform: "iOSSimulator")) == nil)
        #expect(Self.path(of: withSimulator.defaultDependencyCache(for: Self.file(platform: "iOSSimulator"))) == Self.cache("iOSSimulator", "27.0").path)
    }

    @Test("A folder is offered every registered cache and this Mac's, whatever its first binary was built for")
    func foldersAreOfferedEveryCache() {
        let fileSettings = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0"), Self.cache("tvOS", "27.0")])
        let folder = Self.file(platform: "iOS", content: .folder)

        #expect(fileSettings.dependencyCaches(for: folder).map(\.platformName) == ["iOS", "tvOS"])
        #expect(Settings.File.canPairWithThisMacsCache(folder))
    }

    @Test("A file or a bundle is offered the caches of its own platform, and this Mac's only when it was built for macOS or Mac Catalyst")
    func filesAreOfferedTheirPlatformsCaches() {
        let fileSettings = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0"), Self.cache("tvOS", "27.0")])

        #expect(fileSettings.dependencyCaches(for: Self.file(platform: "iOS", content: .bundle)).map(\.platformName) == ["iOS"])
        #expect(!Settings.File.canPairWithThisMacsCache(Self.file(platform: "iOS", content: .bundle)))
        #expect(Settings.File.canPairWithThisMacsCache(Self.file(platform: "macCatalyst")))
        #expect(!Settings.File.canPairWithThisMacsCache(Self.file(platform: "macOS", content: .dyldSharedCache)), "a cache is its own")
    }

    @Test("A cache, a file of another platform with nothing registered, or a file that names no platform reads alone")
    func otherwiseTheFileReadsAlone() {
        let fileSettings = Settings.File(dependencyCaches: [Self.cache("iOS", "27.0")])

        #expect(fileSettings.defaultDependencyCache(for: Self.file(platform: "iOS", content: .dyldSharedCache)) == nil)
        #expect(fileSettings.defaultDependencyCache(for: Self.file(platform: "tvOS")) == nil)
        #expect(fileSettings.defaultDependencyCache(for: Self.file(platform: nil)) == nil)
    }
}
