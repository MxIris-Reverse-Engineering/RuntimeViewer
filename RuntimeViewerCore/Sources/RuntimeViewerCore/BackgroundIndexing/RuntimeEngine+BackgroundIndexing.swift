import Foundation
import FoundationToolbox
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await dispatch(IsImageIndexedCommand(path: path))
    }

    func _isImageIndexed(path: String) async -> Bool {
        let normalized = imageCatalog.canonicalImagePath(path)
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
        try await dispatch(MainExecutablePathCommand())
    }

    /// Like `loadImage(at:)` but does **not** call `reloadData()` and does
    /// **not** emit `imageDidLoadPublisher`.
    ///
    /// Both omissions are deliberate. Triggering `reloadData()` for every
    /// image visited by a depth-2+ BFS would storm the sidebar during a
    /// background batch; emitting `imageDidLoadPublisher` would feed
    /// `RuntimeBackgroundIndexingCoordinator`'s image-loaded pump and
    /// recursively spawn a fresh batch for every image we just indexed.
    ///
    /// It does emit `imageDidIndexPublisher`, which nothing in background
    /// indexing listens to; the Find corpus coordinator does.
    public func loadImageForBackgroundIndexing(at path: String) async throws {
        _ = try await dispatch(LoadImageForBackgroundIndexingCommand(path: path))
        imageDidIndexSubject.send(path)
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
        let canonical = imageCatalog.canonicalImagePath(path)
        if !imageList.contains(canonical) {
            try imageCatalog.prepareImage(at: canonical)
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
        await (try? dispatch(CanOpenImageCommand(path: path))) ?? false
    }

    func rpaths(for path: String) async throws -> [String] {
        try await dispatch(RpathsCommand(path: path))
    }

    func dependencies(for path: String,
                      ancestorRpaths: [String],
                      mainExecutablePath: String) async throws
        -> [(installName: String, resolvedPath: String?)] {
        let entries: [RuntimeDependencyEntry] = try await dispatch(
            DependenciesCommand(
                path: path,
                ancestorRpaths: ancestorRpaths,
                mainExecutablePath: mainExecutablePath,
            ),
        )
        // Manager-facing API still uses the tuple shape it was written
        // against; only the wire form needs a named struct (tuples aren't
        // Codable). Repack here.
        return entries.map { ($0.installName, $0.resolvedPath) }
    }

    func reloadDataAfterBackgroundIndexing() async {
        await reloadData(isReloadImageNodes: false)
    }

    func ownerBackgroundIndexingManager(forImageAt path: String) async -> RuntimeBackgroundIndexingManager? {
        guard let owner = sharedCacheOwner(forImageAt: path) else { return nil }
        return await owner.backgroundIndexingManager
    }

    nonisolated func isOwnedSharedCacheImage(_ path: String) -> Bool {
        sharedCacheOwnersSubject.value?.partition.platform(ofImageAt: canonicalImagePath(path)) != nil
    }

    nonisolated var borrowerName: String {
        source.description
    }
}

// MARK: - Local implementations of the BFS metadata methods

/// The local arm of each answers from the engine's image catalog: what dyld
/// loaded into this process, or the images of an offline file. The walk and
/// the dependency rules themselves are the catalog's; see
/// `RuntimeImageCatalog.dependencyEntries(ofImageAt:ancestorRpaths:mainExecutablePath:)`.
extension RuntimeEngine {
    func _canOpenImage(at path: String) -> Bool {
        imageCatalog.canOpenImage(at: path)
    }

    func _rpaths(for path: String) -> [String] {
        imageCatalog.rpaths(ofImageAt: path)
    }

    func _dependencies(for path: String,
                       ancestorRpaths: [String],
                       mainExecutablePath: String)
        -> [RuntimeDependencyEntry] {
        imageCatalog.dependencyEntries(
            ofImageAt: path,
            ancestorRpaths: ancestorRpaths,
            mainExecutablePath: mainExecutablePath,
        )
    }
}

// MARK: - Request types

extension RuntimeEngine {
    struct CanOpenImageCommand: RuntimeEngineCommand {
        let path: String
        static var commandName: String { CommandName.canOpenImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> Bool {
            await engine._canOpenImage(at: path)
        }
    }

    struct RpathsCommand: RuntimeEngineCommand {
        let path: String
        static var commandName: String { CommandName.rpathsForImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [String] {
            await engine._rpaths(for: path)
        }
    }

    struct DependenciesCommand: RuntimeEngineCommand {
        let path: String
        let ancestorRpaths: [String]
        let mainExecutablePath: String
        static var commandName: String { CommandName.dependenciesForImage.commandName }
        func perform(on engine: RuntimeEngine) async throws -> [RuntimeDependencyEntry] {
            await engine._dependencies(
                for: path,
                ancestorRpaths: ancestorRpaths,
                mainExecutablePath: mainExecutablePath,
            )
        }
    }
}
