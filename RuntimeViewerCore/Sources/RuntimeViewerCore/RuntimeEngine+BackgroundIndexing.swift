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

    /// Like `loadImage(at:)` but does **not** call `reloadData()` and does
    /// **not** emit `imageDidLoadPublisher`.
    ///
    /// Both omissions are deliberate. Triggering `reloadData()` for every
    /// image visited by a depth-2+ BFS would storm the sidebar during a
    /// background batch; emitting `imageDidLoadPublisher` would feed
    /// `RuntimeBackgroundIndexingCoordinator`'s image-loaded pump and
    /// recursively spawn a fresh batch for every image we just indexed.
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

    func dependencies(for path: String,
                      ancestorRpaths: [String],
                      mainExecutablePath: String) async throws
        -> [(installName: String, resolvedPath: String?)]
    {
        guard let image = DyldUtilities.machOImage(forPath: path) else {
            return []
        }
        let resolver = DylibPathResolver()
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
                    mainExecutablePath: mainExecutablePath
                )
                // Two link modes where dyld is allowed to never produce a
                // loaded image at BFS time:
                //
                //  • LC_LOAD_WEAK_DYLIB — dyld silently skips when the target
                //    isn't loadable. Two manifestations: (1) install name
                //    doesn't resolve to anything on disk (e.g. Xcode omits
                //    the embed for newer deployment targets); (2) install
                //    name resolves to an embedded copy but dyld uses the
                //    shared-cache version instead (e.g. Xcode embeds
                //    `libswiftCompatibilitySpan.dylib` whose install name is
                //    `/usr/lib/swift/...`; on hosts where the shared cache
                //    already ships it, the bundle copy is never loaded as a
                //    separate image).
                //
                //  • DYLIB_USE_DELAYED_INIT — dyld postpones loading until
                //    the first symbol access (e.g. Foundation's delay-init
                //    edge to `/usr/lib/libcmark-gfm.dylib`). At BFS time the
                //    image is on disk / in the shared cache but not yet
                //    registered, so `machOImage(forPath:)` returns nil.
                //
                // In both cases `expandDependencyGraph`'s `canOpenImage`
                // check would mark the node `.failed("cannot open MachOImage")`,
                // flooding the popover with red ✗ rows for misses the runtime
                // explicitly tolerates. Drop them from the dependency list
                // instead.
                let isShadowable = dependency.type == .weakLoad
                    || dependency.useFlags.contains(.delayed_init)
                if isShadowable {
                    if resolvedPath == nil {
                        return nil
                    }
                    if let resolvedPath,
                       DyldUtilities.machOImage(forPath: resolvedPath) == nil {
                        return nil
                    }
                }
                return (installName, resolvedPath)
            }
    }
}
