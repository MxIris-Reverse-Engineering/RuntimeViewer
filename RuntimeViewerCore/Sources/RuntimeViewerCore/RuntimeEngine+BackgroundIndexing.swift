import Foundation
import FoundationToolbox
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await dispatch(IsImageIndexedRequest(path: path))
    }

    func _isImageIndexed(path: String) async -> Bool {
        let normalized = DyldUtilities.patchImagePathForDyld(path)
        let hasObjC = await objcSectionFactory.hasCachedSection(for: normalized)
        let hasSwift = await swiftSectionFactory.hasCachedSection(for: normalized)
        return hasObjC && hasSwift
    }

    /// Path of the target process's main executable.
    ///
    /// `imageNames().first` is unreliable under `DYLD_INSERT_LIBRARIES`
    /// (Xcode injects `libLogRedirect.dylib` at index 0 during debug runs).
    /// `_NSGetExecutablePath` (wrapped by `DyldUtilities.mainExecutablePath`)
    /// always returns the host binary.
    public func mainExecutablePath() async throws -> String {
        try await dispatch(MainExecutablePathRequest())
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
        _ = try await dispatch(LoadImageForBackgroundIndexingRequest(path: path))
    }

    /// Local implementation of `loadImageForBackgroundIndexing(at:)`. Mirrors
    /// `_loadImage(at:)` byte-for-byte sans `reloadData` / `imageDidLoad`
    /// emission. See `_loadImage(at:)` for the canonicalization rationale.
    ///
    /// Skips `dlopen` when dyld already has the image mapped. The indexer's
    /// dependency-graph BFS can reach the host process's own main executable
    /// (which `dlopen` refuses to re-open by definition) and, on iOS
    /// Simulator, system images whose canonical path differs from dyld's
    /// runtime form due to `DYLD_ROOT_PATH` rewriting (the rewritten path
    /// resolves to `(no such file)` on disk). Either failure mode raises
    /// `DyldOpenError`, which the request-handler catch arm echoes back as
    /// a bare `RuntimeNetworkRequestError` carrying no `identifier` field —
    /// the peer fails envelope decode, echoes its own bare error, and both
    /// sides ping-pong on the shared `sendSemaphore`, starving every other
    /// request (image-list pushes, sidebar `isImageLoaded`, indexing
    /// progress). See Changelogs/v2.1.0-beta.4.md for the full failure
    /// description. Section caching below is idempotent on already-loaded
    /// images so the rest of the indexing pipeline still runs.
    func _loadImageForBackgroundIndexing(at path: String) async throws {
        let canonical = DyldUtilities.patchImagePathForDyld(path)
        if !imageList.contains(canonical) {
            try DyldUtilities.loadImage(at: canonical)
        }
        _ = try await objcSectionFactory.section(for: canonical)
        _ = try await swiftSectionFactory.section(for: canonical)
        loadedImagePaths.insert(canonical)
    }
}

// MARK: - BackgroundIndexingEngineRepresenting

extension RuntimeEngine: RuntimeBackgroundIndexingEngineRepresenting {
    /// All three metadata methods below `dispatch` so they query the engine
    /// hosting the actual binary (`DyldUtilities.machOImage(forPath:)` reads
    /// the current process's dyld, which is only correct for the local
    /// arm). Without dispatch, remote sources (XPC / Bonjour / iOS Simulator)
    /// would resolve every dependency path against the client process's
    /// dyld map — which doesn't know about the remote app's images — and
    /// `dependencies(for: rootPath)` would always return `[]`, leaving the
    /// BFS stuck at the root image. That's why pre-fix remote engines only
    /// ever indexed their own main executable instead of the full
    /// dependency closure.
    func canOpenImage(at path: String) async -> Bool {
        // Errors map to `false` (treat as "can't open"), matching the
        // pre-dispatch behaviour where a missing image silently returned
        // `false` rather than throwing.
        (try? await dispatch(CanOpenImageRequest(path: path))) ?? false
    }

    func rpaths(for path: String) async throws -> [String] {
        try await dispatch(RpathsRequest(path: path))
    }

    func dependencies(for path: String,
                      ancestorRpaths: [String],
                      mainExecutablePath: String) async throws
        -> [(installName: String, resolvedPath: String?)]
    {
        let entries: [RuntimeDependencyEntry] = try await dispatch(
            DependenciesRequest(
                path: path,
                ancestorRpaths: ancestorRpaths,
                mainExecutablePath: mainExecutablePath
            )
        )
        // Manager-facing API still uses the tuple shape it was written
        // against; only the wire form needs a named struct (tuples aren't
        // Codable). Repack here.
        return entries.map { ($0.installName, $0.resolvedPath) }
    }
}

// MARK: - Local implementations of the BFS metadata methods

extension RuntimeEngine {
    func _canOpenImage(at path: String) -> Bool {
        DyldUtilities.machOImage(forPath: path) != nil
    }

    func _rpaths(for path: String) -> [String] {
        guard let image = DyldUtilities.machOImage(forPath: path) else {
            return []
        }
        return image.rpaths
    }

    func _dependencies(for path: String,
                       ancestorRpaths: [String],
                       mainExecutablePath: String)
        -> [RuntimeDependencyEntry]
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
                return RuntimeDependencyEntry(installName: installName, resolvedPath: resolvedPath)
            }
    }
}

// MARK: - Wire types

/// Codable equivalent of the BFS metadata tuple. Tuples can't conform to
/// `Codable`, so the on-wire form uses this struct and the public
/// `dependencies(...)` API repacks to tuples at the dispatch seam.
public struct RuntimeDependencyEntry: Codable, Sendable {
    public let installName: String
    public let resolvedPath: String?

    public init(installName: String, resolvedPath: String?) {
        self.installName = installName
        self.resolvedPath = resolvedPath
    }
}

// MARK: - Request types

extension RuntimeEngine {
    struct CanOpenImageRequest: RuntimeEngineRequest {
        let path: String
        static var commandName: String { CommandNames.canOpenImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._canOpenImage(at: path)
        }
    }

    struct RpathsRequest: RuntimeEngineRequest {
        let path: String
        static var commandName: String { CommandNames.rpathsForImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            await engine._rpaths(for: path)
        }
    }

    struct DependenciesRequest: RuntimeEngineRequest {
        let path: String
        let ancestorRpaths: [String]
        let mainExecutablePath: String
        static var commandName: String { CommandNames.dependenciesForImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeDependencyEntry] {
            await engine._dependencies(
                for: path,
                ancestorRpaths: ancestorRpaths,
                mainExecutablePath: mainExecutablePath
            )
        }
    }
}
