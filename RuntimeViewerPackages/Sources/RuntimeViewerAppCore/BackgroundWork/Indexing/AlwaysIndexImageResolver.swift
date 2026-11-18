import Foundation
import RuntimeViewerCore
import RuntimeViewerCommunication

/// Maps an Always Index row's identifier — a full path, or an image's file name — to the image it
/// names on one engine.
///
/// A row names an image the engine's process has loaded. On an engine that borrows from the
/// shared cache owners it can also name any image of the shared cache an owner keeps, loaded or
/// not: the owner loads the image to index it, so a row for a framework the process never loaded
/// is indexed all the same. A file name two shared cache images have — SwiftUI is one, built once
/// for macOS and once for Mac Catalyst — names the one built for the platform of the engine's
/// process, the only one that process could load; failing that, the other.
struct AlwaysIndexImageResolver {
    /// The images the engine's process has loaded, in the order of its image list.
    let loadedImagePaths: [String]

    /// The engine's owners, `nil` while it serves every image itself.
    let sharedCacheOwners: RuntimeSharedCacheOwners?

    /// The platform of the engine's process.
    let processPlatform: RuntimeSharedCacheImagePlatform

    init(loadedImagePaths: [String], sharedCacheOwners: RuntimeSharedCacheOwners?, source: RuntimeSource) {
        self.loadedImagePaths = loadedImagePaths
        self.sharedCacheOwners = sharedCacheOwners
        processPlatform = Self.processPlatform(of: source, loadedImagePaths: loadedImagePaths, partition: sharedCacheOwners?.partition)
    }

    /// The image `identifier` names, or `nil` when it names none on the engine: the caller skips
    /// the row and tries again once the engine's image list changes.
    func imagePath(for identifier: String) -> String? {
        let trimmedIdentifier = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedIdentifier.isEmpty else { return nil }
        if trimmedIdentifier.hasPrefix("/") {
            if loadedImagePaths.contains(trimmedIdentifier) {
                return trimmedIdentifier
            }
            return isSharedCacheImageWithOwner(trimmedIdentifier) ? trimmedIdentifier : nil
        }
        let loadedMatches = loadedImagePaths.filter { Self.fileName(of: $0) == trimmedIdentifier }
        if let loadedMatch = preferredMatch(among: loadedMatches) {
            return loadedMatch
        }
        guard let partition = sharedCacheOwners?.partition else { return nil }
        let sharedCacheMatches = partition.imagePaths
            .filter { Self.fileName(of: $0) == trimmedIdentifier && isSharedCacheImageWithOwner($0) }
            .sorted()
        return preferredMatch(among: sharedCacheMatches)
    }

    /// Whether `imagePath` is a shared cache image some owner keeps: a Mac Catalyst image only
    /// while the Mac Catalyst engine is up.
    private func isSharedCacheImageWithOwner(_ imagePath: String) -> Bool {
        sharedCacheOwners?.owner(ofImageAt: imagePath) != nil
    }

    /// The first of `candidates` built for the process's platform, or the first of all.
    private func preferredMatch(among candidates: [String]) -> String? {
        guard let partition = sharedCacheOwners?.partition else { return candidates.first }
        return candidates.first { partition.platform(ofImageAt: $0) == processPlatform } ?? candidates.first
    }

    private static func fileName(of imagePath: String) -> String {
        (imagePath as NSString).lastPathComponent
    }

    /// The Mac Catalyst engine's process is a Mac Catalyst one; any other is when it has loaded an
    /// image built for Mac Catalyst alone, which no macOS process can load.
    static func processPlatform(of source: RuntimeSource, loadedImagePaths: [String], partition: RuntimeSharedCachePartition?) -> RuntimeSharedCacheImagePlatform {
        if case .remote(_, let identifier, _) = source, identifier == .macCatalyst {
            return .macCatalyst
        }
        guard let partition else { return .macOS }
        return loadedImagePaths.contains { partition.platform(ofImageAt: $0) == .macCatalyst } ? .macCatalyst : .macOS
    }
}
