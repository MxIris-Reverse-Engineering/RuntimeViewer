public import Foundation
import MetaCodable
public import RuntimeViewerCore

extension Settings {
    /// Reading Mach-O files, bundles and dyld shared caches from disk.
    ///
    /// A file built for macOS or Mac Catalyst reads what it links from this
    /// Mac's dyld shared cache. A file built for another platform reads it
    /// from a cache registered here, picked by ``defaultDependencyCache(for:)``.
    @Codable
    @MemberInit
    public struct Offline: Sendable {
        /// The dyld shared caches files built for other platforms are paired
        /// with, in the order they were registered.
        @Default([DependencyCache]())
        public var dependencyCaches: [DependencyCache]

        public static let `default` = Self()

        /// A registered dyld shared cache: its main file, and what its header
        /// said when it was registered — enough to show it and to pick it
        /// without opening it again.
        @Codable
        @MemberInit
        public struct DependencyCache: Sendable, Hashable, Identifiable {
            /// The path of the cache's main file.
            public var path: String

            /// `RuntimeOfflineFile.Platform.name`: `iOS`, `iOSSimulator`, …
            public var platformName: String

            /// The operating system version, such as `27.0`.
            public var version: String

            /// Such as `arm64e`.
            public var architecture: String

            /// The cache's UUID, as text.
            public var uuid: String

            public var id: String { path }

            /// The entry for a cache whose header was just read.
            public init(summary: RuntimeDyldSharedCacheSummary) {
                self.init(
                    path: summary.mainFileURL.path,
                    platformName: summary.platform?.name ?? "",
                    version: summary.platform?.version ?? "",
                    architecture: summary.architecture,
                    uuid: summary.uuid.uuidString
                )
            }
        }
    }
}

extension Settings.Offline {
    /// The dyld shared cache `file` reads what it links from, unless the user
    /// picks another.
    ///
    /// A file built for macOS or Mac Catalyst: this Mac's cache. Otherwise
    /// the registered caches of the file's platform — a simulator's file only
    /// pairs with that simulator's caches — and among them the oldest one no
    /// older than the SDK the file was built with, or the newest when all are
    /// older. `nil` — the file alone — when no registered cache matches, the
    /// file says nothing about its platform, or it is a cache itself.
    public func defaultDependencyCache(for file: RuntimeOfflineFile) -> RuntimeOfflineFile.DependencyCache? {
        if case .dyldSharedCache = file.content { return nil }
        guard let platform = file.platform else { return nil }
        if Self.platformNamesPairedWithThisMac.contains(platform.name) {
            return .systemDyldSharedCache
        }
        let candidates = dependencyCaches
            .filter { $0.platformName == platform.name }
            .sorted { Self.versionComponents($0.version).lexicographicallyPrecedes(Self.versionComponents($1.version)) }
        let fileVersion = Self.versionComponents(platform.version)
        let chosen = candidates.first { !Self.versionComponents($0.version).lexicographicallyPrecedes(fileVersion) } ?? candidates.last
        return chosen.map { .dyldSharedCache(URL(fileURLWithPath: $0.path)) }
    }

    /// The registered caches a file of `platformName` can be paired with.
    public func dependencyCaches(forPlatformNamed platformName: String) -> [DependencyCache] {
        dependencyCaches.filter { $0.platformName == platformName }
    }

    /// The registered caches `file` can be paired with: those of its
    /// platform, or every one for a folder. A folder can hold binaries of
    /// several platforms — an `.xcframework` does — and the platform it was
    /// paired by is only its first binary's.
    public func dependencyCaches(for file: RuntimeOfflineFile) -> [DependencyCache] {
        if case .folder = file.content { return dependencyCaches }
        return dependencyCaches(forPlatformNamed: file.platform?.name ?? "")
    }

    /// Whether `file` can be paired with this Mac's own dyld shared cache: a
    /// file built for macOS or Mac Catalyst, or a folder, whatever its first
    /// binary was built for.
    public static func canPairWithThisMacsCache(_ file: RuntimeOfflineFile) -> Bool {
        switch file.content {
        case .folder:
            true
        case .dyldSharedCache:
            false
        case .machO, .bundle:
            file.platform.map { platformNamesPairedWithThisMac.contains($0.name) } ?? false
        }
    }

    /// Platforms whose files read this Mac's own dyld shared cache.
    public static let platformNamesPairedWithThisMac: Set<String> = ["macOS", "macCatalyst"]

    /// `27.0.1` as `[27, 0, 1]`, padded so `27` and `27.0` compare equal.
    private static func versionComponents(_ version: String) -> [Int] {
        var components = version.split(separator: ".").map { Int($0) ?? 0 }
        while components.count < 3 {
            components.append(0)
        }
        return components
    }
}
