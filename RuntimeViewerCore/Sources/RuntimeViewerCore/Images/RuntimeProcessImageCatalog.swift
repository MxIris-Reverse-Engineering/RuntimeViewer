import Foundation
import MachOKit
import MachODependencies

/// The images dyld loaded into this process — what every engine read before
/// offline files: the local runtime, the Mac Catalyst runtime, an injected
/// payload, a test.
///
/// Stateless: each answer is read off dyld when asked, so images loaded later
/// are listed by the next `imagePaths()`.
struct RuntimeProcessImageCatalog: RuntimeImageCatalog {
    typealias Reading = RuntimeLoadedImageReading

    func imagePaths() -> [String] {
        DyldUtilities.inspectableImageNames()
    }

    func rootNodes() -> [RuntimeImageNode] {
        [DyldUtilities.dyldSharedCacheImageRootNode, DyldUtilities.otherImageRootNode]
    }

    /// Prefixes the process's `DYLD_ROOT_PATH`, which is how dyld names the
    /// images of a simulator runtime.
    func canonicalImagePath(_ imagePath: String) -> String {
        DyldUtilities.patchImagePathForDyld(imagePath)
    }

    /// dyld is asked by path, and matches a loaded image by its file name
    /// when the path is spelled otherwise.
    func listedImagePath(forResolvedPath resolvedPath: String) -> String {
        resolvedPath
    }

    func machO(forImagePath imagePath: String) -> MachOImage? {
        DyldUtilities.machOImage(forPath: imagePath)
    }

    func prepareImage(at imagePath: String) throws {
        try DyldUtilities.loadImage(at: imagePath)
    }

    /// The runtime knows: the image of the class object or protocol it
    /// returns for the name, keyed by the path dyld reported for it.
    func image(definingObjCType name: RuntimeObjCName) async -> (imagePath: String, machO: MachOImage)? {
        guard let machO = MachOImage.image(forName: name) else { return nil }
        return (machO.imagePath, machO)
    }

    func mainExecutablePath() -> String {
        DyldUtilities.mainExecutablePath()
    }

    /// One process, one main executable.
    func mainExecutablePath(forImageAt imagePath: String) -> String? {
        nil
    }

    func isSharedCacheImage(_ path: String) -> Bool {
        DyldUtilities.isInDyldSharedCache(path)
    }

    func dependencySearchPaths(forImageAt imagePath: String) -> [DependencySearchPath] {
        [.systemDyldSharedCache]
    }
}
