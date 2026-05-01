import Foundation
import FoundationToolbox
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await request {
            let normalized = DyldUtilities.patchImagePathForDyld(path)
            let hasObjC = await objcSectionFactory.hasCachedSection(for: normalized)
            let hasSwift = await swiftSectionFactory.hasCachedSection(for: normalized)
            return hasObjC && hasSwift
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .isImageIndexed, request: path)
        }
    }

    /// Path of the target process's main executable.
    public func mainExecutablePath() async throws -> String {
        try await request {
            // `imageNames().first` is unreliable under `DYLD_INSERT_LIBRARIES`
            // (Xcode injects `libLogRedirect.dylib` at index 0 during debug
            // runs). `_NSGetExecutablePath` always returns the host binary.
            DyldUtilities.mainExecutablePath()
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .mainExecutablePath)
        }
    }

    /// Like `loadImage(at:)` but does **not** call `reloadData()`.
    /// Used by the background indexing manager to avoid UI refresh storms.
    public func loadImageForBackgroundIndexing(at path: String) async throws {
        try await request {
            // Mirror loadImage(at:) byte-for-byte sans reloadData. See loadImage
            // for the canonicalization rationale.
            let canonical = DyldUtilities.patchImagePathForDyld(path)
            try DyldUtilities.loadImage(at: canonical)
            _ = try await objcSectionFactory.section(for: canonical)
            _ = try await swiftSectionFactory.section(for: canonical)
            loadedImagePaths.insert(canonical)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(
                name: .loadImageForBackgroundIndexing, request: path)
        }
    }
}

// MARK: - BackgroundIndexingEngineRepresenting

extension RuntimeEngine: RuntimeBackgroundIndexingEngineRepresenting {
    func canOpenImage(at path: String) -> Bool {
        DyldUtilities.machOImage(forPath: path) != nil
    }

    func rpaths(for path: String) -> [String] {
        guard let image = DyldUtilities.machOImage(forPath: path) else {
            return []
        }
        return image.rpaths
    }

    func dependencies(for path: String, ancestorRpaths: [String]) async throws
        -> [(installName: String, resolvedPath: String?)]
    {
        guard let image = DyldUtilities.machOImage(forPath: path) else {
            return []
        }
        let resolver = DylibPathResolver()
        let main = try await mainExecutablePath()
        // dyld searches the union of every loader's LC_RPATH walking up the
        // chain to the main executable plus the image's own LC_RPATH. The BFS
        // accumulates ancestors into `ancestorRpaths`; appending self-rpaths
        // matches dyld's lookup order (loaders first, then self).
        let mergedRpaths = ancestorRpaths + image.rpaths
        return image.dependencies
            .filter { $0.type != .lazyLoad }
            .compactMap { dependency in
                let installName = dependency.dylib.name
                let resolvedPath = resolver.resolve(
                    installName: installName,
                    imagePath: path,
                    rpaths: mergedRpaths,
                    mainExecutablePath: main
                )
                // LC_LOAD_WEAK_DYLIB: dyld silently skips at runtime when the
                // target isn't on disk (e.g. Xcode embeds
                // `libswiftCompatibilitySpan.dylib` only for older deployment
                // targets). Mirror that here — surfacing it as `.failed("path
                // unresolved")` floods the popover with red ✗ rows for a
                // miss the runtime explicitly tolerates.
                if resolvedPath == nil, dependency.type == .weakLoad {
                    return nil
                }
                return (installName, resolvedPath)
            }
    }
}
