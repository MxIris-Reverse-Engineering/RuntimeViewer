import Foundation
import MachOKit
import MachODependencies

/// Where an engine's images come from, and how one of them is found by path.
///
/// An engine that serves images itself — the local runtime, an injected
/// payload, the offline service — reads every image through one catalog:
/// the images dyld loaded into this process (`RuntimeProcessImageCatalog`), or
/// the images of a file on disk. The engine asks it for the image list and the
/// sidebar's root nodes, the section factories ask it for the image behind a
/// path, and background indexing asks it how an image's dependencies resolve.
/// An engine that forwards its requests to another process has a catalog too,
/// but never consults it.
protocol RuntimeImageCatalog<Reading>: Sendable {
    associatedtype Reading: RuntimeImageReading

    typealias MachO = Reading.MachO

    /// Every image an engine over this catalog lists — each of which
    /// `machO(forImagePath:)` can produce.
    func imagePaths() -> [String]

    /// The sidebar's root nodes over those images.
    func rootNodes() -> [RuntimeImageNode]

    /// The spelling the section caches key an image by.
    func canonicalImagePath(_ imagePath: String) -> String

    /// The image behind `imagePath`, or `nil` when the catalog has none.
    func machO(forImagePath imagePath: String) -> MachO?

    /// What `loadImage(at:)` does before the image's sections are built:
    /// `dlopen` it into this process, or nothing for an image read from disk.
    func prepareImage(at imagePath: String) throws

    /// The image that defines the Objective-C class or protocol `name`, for a
    /// reference no indexed image answers — with the path its sections are
    /// keyed by.
    func image(definingObjCType name: RuntimeObjCName) async -> (imagePath: String, machO: MachO)?

    /// The main executable `@executable_path` expands against.
    func mainExecutablePath() -> String

    /// Whether `path`, which names no file on disk, is an image of the dyld
    /// shared cache this catalog's images come from.
    func isSharedCacheImage(_ path: String) -> Bool

    /// Where MachOSwiftSection looks for the images an image links when it
    /// reads one from a file: the Swift indexer's dependency closure and the
    /// static field layout. Images read from this process need none — the
    /// runtime resolves them — and keep the library's default.
    var dependencySearchPaths: [DependencySearchPath] { get }
}

// MARK: - Dependencies

extension RuntimeImageCatalog {
    /// Whether the catalog can produce the image at `path`.
    func canOpenImage(at path: String) -> Bool {
        machO(forImagePath: path) != nil
    }

    /// The image's own `LC_RPATH` entries.
    func rpaths(ofImageAt path: String) -> [String] {
        machO(forImagePath: path)?.rpaths ?? []
    }

    /// The images `path` links, each with the path its install name resolves
    /// to — the edges background indexing walks.
    ///
    /// dyld searches the union of every loader's `LC_RPATH` up the chain to the
    /// main executable plus the image's own; the walk accumulates the
    /// ancestors' into `ancestorRpaths`, and appending the image's own matches
    /// dyld's order (loaders first, then self).
    func dependencyEntries(
        ofImageAt path: String,
        ancestorRpaths: [String],
        mainExecutablePath: String
    ) -> [RuntimeDependencyEntry] {
        guard let image = machO(forImagePath: path) else { return [] }
        let resolver = DylibPathResolver(isSharedCacheImage: { [self] in isSharedCacheImage($0) })
        let mergedRpaths = ancestorRpaths + image.rpaths
        return image.dependencies
            .filter { $0.type != .lazyLoad }
            .compactMap { dependency in
                let installName = dependency.dylib.name
                let resolvedPath = resolver.resolve(
                    installName: installName,
                    imagePath: path,
                    rpaths: mergedRpaths,
                    mainExecutablePath: mainExecutablePath,
                )
                // Two link modes where dyld is allowed to never produce a
                // loaded image:
                //
                //  • LC_LOAD_WEAK_DYLIB — dyld silently skips a target that
                //    is not loadable. Two manifestations: (1) the install name
                //    resolves to nothing on disk (e.g. Xcode omits the embed
                //    for newer deployment targets); (2) it resolves to an
                //    embedded copy, but dyld uses the shared cache's instead
                //    (e.g. Xcode embeds `libswiftCompatibilitySpan.dylib`,
                //    whose install name is `/usr/lib/swift/...`; on hosts whose
                //    shared cache already ships it, the bundle copy is never
                //    loaded as a separate image).
                //
                //  • DYLIB_USE_DELAYED_INIT — dyld postpones loading until the
                //    first symbol access (e.g. Foundation's delay-init edge to
                //    `/usr/lib/libcmark-gfm.dylib`). At walk time the image is
                //    on disk or in the shared cache but not yet loaded, so the
                //    process catalog cannot produce it.
                //
                // In both cases the walk's `canOpenImage` check would mark the
                // node failed, flooding the Report with misses the runtime
                // explicitly tolerates. Drop them from the dependency list
                // instead.
                let isShadowable = dependency.type == .weakLoad
                    || dependency.useFlags.contains(.delayed_init)
                if isShadowable {
                    guard let resolvedPath, canOpenImage(at: resolvedPath) else {
                        return nil
                    }
                }
                return RuntimeDependencyEntry(installName: installName, resolvedPath: resolvedPath)
            }
    }
}
