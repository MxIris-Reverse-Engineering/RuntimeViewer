public import Foundation
import MachOKit

/// What a dyld shared cache's header says about it: enough to show the cache
/// and to pair files with it, without opening it again.
public struct RuntimeDyldSharedCacheSummary: Sendable, Hashable {
    /// The cache's main file — not a subcache, nor its symbols file.
    public let mainFileURL: URL

    /// The operating system the cache belongs to, and its version.
    public let platform: RuntimeOfflineFile.Platform?

    /// The architecture its magic names, such as `arm64e`.
    public let architecture: String

    public let uuid: UUID

    /// Reads the header of the cache at `url`, which may name the main file,
    /// a subcache or the symbols file. Throws `RuntimeOfflineFileError` when
    /// it is no dyld shared cache.
    public init(contentsOf url: URL) throws {
        let file = try RuntimeOfflineFile(contentsOf: url)
        guard case .dyldSharedCache = file.content else {
            throw RuntimeOfflineFileError.unsupportedContent(url)
        }
        let cache: DyldCache
        do {
            cache = try DyldCache(url: file.url)
        } catch {
            throw RuntimeOfflineFileError.unreadable(file.url)
        }
        self.mainFileURL = file.url
        self.platform = file.platform
        self.architecture = cache.header.magic
            .replacingOccurrences(of: "dyld_v1", with: "")
            .trimmingCharacters(in: .whitespaces)
        self.uuid = cache.header.uuid
    }
}
