import Foundation
import FoundationToolbox
import MachOKit
import MachODependencies

/// This process's images, as a framework instance lists them: the images
/// loaded through the engine — the frameworks the user picked and anything
/// loaded first to let them in, in order, a load dyld refused included — and
/// the images dyld brought in with them from outside the shared cache.
/// Nothing that was loaded when the instance started, which is RuntimeViewer's
/// own scaffolding, and no shared cache root: the instance borrows those
/// images from My Mac.
///
/// Paths are spelled as dyld lists them (`DyldUtilities.pathAsDyldListsIt`),
/// so an image asked for through a symbolic link is one entry, not two.
/// Everything but the lists is the process catalog's.
final class RuntimeFrameworkInstanceImageCatalog: RuntimeImageCatalog {
    typealias Reading = RuntimeLoadedImageReading

    static let frameworksRootNodeName = "Frameworks"
    static let dependenciesRootNodeName = "Dependencies"

    private let processCatalog = RuntimeProcessImageCatalog()

    /// The images dyld had loaded when the instance started.
    private let baselineImagePaths: Set<String>

    /// The images loaded through the engine, as dyld lists them, in order.
    private let imagePathsLoadedThroughEngine = Mutex<[String]>([])

    init(baselineImagePaths: Set<String>) {
        self.baselineImagePaths = baselineImagePaths
    }

    /// The lists change with every load, so the engine rebuilds the sidebar's
    /// nodes after each one.
    var rootNodesFollowLoads: Bool { true }

    /// The images loaded through the engine that dyld holds, then the others
    /// it brought in.
    func imagePaths() -> [String] {
        let loaded = loadedImagePaths()
        return frameworkImagePaths().filter { loaded.contains($0) } + dependencyImagePaths()
    }

    /// "Frameworks", with a load dyld refused listed as an image not loaded,
    /// and "Dependencies".
    func rootNodes() -> [RuntimeImageNode] {
        [
            RuntimeImageNode.rootNode(for: frameworkImagePaths(), name: Self.frameworksRootNodeName),
            RuntimeImageNode.rootNode(for: dependencyImagePaths(), name: Self.dependenciesRootNodeName),
        ]
    }

    func canonicalImagePath(_ imagePath: String) -> String {
        processCatalog.canonicalImagePath(imagePath)
    }

    func listedImagePath(forResolvedPath resolvedPath: String) -> String {
        processCatalog.listedImagePath(forResolvedPath: resolvedPath)
    }

    func machO(forImagePath imagePath: String) -> MachOImage? {
        processCatalog.machO(forImagePath: imagePath)
    }

    /// Notes the image as loaded through the engine — before `dlopen`, so a
    /// refused one is listed too — then loads it.
    func prepareImage(at imagePath: String) throws {
        let listedPath = DyldUtilities.pathAsDyldListsIt(imagePath)
        imagePathsLoadedThroughEngine.withLock { imagePaths in
            if !imagePaths.contains(listedPath) {
                imagePaths.append(listedPath)
            }
        }
        try processCatalog.prepareImage(at: imagePath)
    }

    func image(definingObjCType name: RuntimeObjCName) async -> (imagePath: String, machO: MachOImage)? {
        await processCatalog.image(definingObjCType: name)
    }

    func mainExecutablePath() -> String {
        processCatalog.mainExecutablePath()
    }

    func mainExecutablePath(forImageAt imagePath: String) -> String? {
        processCatalog.mainExecutablePath(forImageAt: imagePath)
    }

    func isSharedCacheImage(_ path: String) -> Bool {
        processCatalog.isSharedCacheImage(path)
    }

    func dependencySearchPaths(forImageAt imagePath: String) -> [DependencySearchPath] {
        processCatalog.dependencySearchPaths(forImageAt: imagePath)
    }

    // MARK: - Lists

    private func frameworkImagePaths() -> [String] {
        imagePathsLoadedThroughEngine.withLock { $0 }
    }

    private func loadedImagePaths() -> Set<String> {
        Set(DyldUtilities.imageNames())
    }

    private func dependencyImagePaths() -> [String] {
        let frameworks = Set(frameworkImagePaths())
        return DyldUtilities.imageNames().filter { imagePath in
            !baselineImagePaths.contains(imagePath)
                && !frameworks.contains(imagePath)
                && !DyldUtilities.isInDyldSharedCache(imagePath)
        }
    }
}
