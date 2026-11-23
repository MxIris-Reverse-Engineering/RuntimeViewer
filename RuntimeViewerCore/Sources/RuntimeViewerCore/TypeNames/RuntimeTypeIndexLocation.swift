public import Foundation

/// Where the SDK type index keeps its module-interface cache:
/// `~/Library/Caches/<bundle identifier>/TypeIndex`, beside the application's
/// `DerivedData`.
///
/// Every process of one application shares it — the app, its XPC services
/// and the command-line tool it embeds each find the `.app` around them — so
/// a module indexed once is read from disk by all of them. It is no
/// `RuntimeDerivedDataKind`: derived data is filed by the dyld shared cache
/// it was made from, the type index by the SDK build (swift-type-indexing
/// adds `<platform>/<SDK version-build>` below this directory). Delete
/// Derived Data removes it with the derived data.
///
/// A command-line tool outside any application keeps its own:
/// `~/Library/Caches/runtime-viewer-cli/TypeIndex`.
public enum RuntimeTypeIndexLocation {
    static let directoryName = "TypeIndex"

    static let standaloneCommandLineDirectoryName = "runtime-viewer-cli"

    /// The cache directory of the process whose main bundle is `bundle`.
    public static func cacheDirectoryURL(forProcessBundle bundle: Bundle) -> URL? {
        guard let cachesDirectoryURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        return cacheDirectoryURL(forBundleAt: bundle.bundleURL, cachesDirectoryURL: cachesDirectoryURL)
    }

    /// The cache directory of the application `location` is the derived data
    /// of.
    public static func cacheDirectoryURL(for location: RuntimeDerivedDataLocation) -> URL {
        location.rootURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    /// `cacheDirectoryURL(forProcessBundle:)` for the bundle at `bundleURL` —
    /// for an executable that is no bundle, the directory it is in — the
    /// caches directory given.
    static func cacheDirectoryURL(forBundleAt bundleURL: URL, cachesDirectoryURL: URL) -> URL {
        var candidateURL = bundleURL.standardizedFileURL
        while candidateURL.pathComponents.count > 1 {
            if candidateURL.pathExtension == "app",
               let location = RuntimeDerivedDataLocation.enclosingApplication(ofBundleAt: candidateURL, cachesDirectoryURL: cachesDirectoryURL) {
                return cacheDirectoryURL(for: location)
            }
            candidateURL = candidateURL.deletingLastPathComponent()
        }
        return cachesDirectoryURL
            .appendingPathComponent(standaloneCommandLineDirectoryName, isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Bytes the cache at `directoryURL` takes on disk.
    public static func allocatedByteCount(at directoryURL: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(at: directoryURL, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return 0
        }
        var byteCount: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            byteCount += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return byteCount
    }

    /// Deletes the cache at `directoryURL`: renames it aside, which makes it
    /// gone for every reader at once, then deletes it in the background. A
    /// process indexing later makes it again; what a running process holds
    /// in memory is not affected.
    public static func deleteAll(at directoryURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        let deletingURL = directoryURL.deletingLastPathComponent()
            .appendingPathComponent("\(directoryName).deleting-\(UUID().uuidString)", isDirectory: true)
        try fileManager.moveItem(at: directoryURL, to: deletingURL)
        Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: deletingURL)
        }
    }
}
