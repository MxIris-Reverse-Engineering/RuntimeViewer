import Foundation
import FoundationToolbox
import MachOKit
import MachODependencies
// `FullDyldCache.cachedHost` comes from MachOKitExtensions, which this
// module reaches through MachOSwiftSection's re-export.
import MachOSwiftSection
import OrderedCollections

/// The images of a file on disk — a Mach-O file, a bundle, a folder or a dyld
/// shared cache — and of the dyld shared cache it is paired with, read as
/// `MachOFile`s.
///
/// What the offline engine reads. No image is run, and the images of a bundle
/// or a folder are not even opened when the catalog is made: they are listed
/// from their headers (`RuntimeDirectoryImageScanner`) and each is opened the
/// first time it is asked for. An open image holds a file descriptor for as
/// long as it lives, and a folder can hold thousands of images, of which a
/// window looks at a few. A Mach-O file is opened at once, and so are the
/// cache's images, which share the mappings of the cache's own files.
///
/// The images of the file itself are keyed by their paths on disk, those of
/// a dyld shared cache by their install names, which is how the cache lists
/// them.
@Loggable(.private)
final class RuntimeFileImageCatalog: RuntimeImageCatalog, @unchecked Sendable {
    typealias Reading = RuntimeFileImageReading

    let file: RuntimeOfflineFile

    /// The paths of the file's own images, in the order the engine lists
    /// them: the file itself for a Mach-O file; a bundle's main executable
    /// first, then every other image by path; every image of a folder by
    /// path; none for a dyld shared cache.
    private let fileImagePaths: [String]

    /// The same paths, to tell a path of the file's from any other.
    private let fileImagePathSet: Set<String>

    /// The slice a Mach-O file is read through. The images of a bundle or a
    /// folder are read through the slice this Mac prefers.
    private let fileSlice: RuntimeOfflineFile.Slice?

    /// The file's images opened so far, by path. An image stays open once it
    /// is: the sections built from it hold it anyway.
    @Mutex
    private var openedFileImages: [String: MachOFile] = [:]

    /// The images of the dyld shared cache the file is, or is paired with, by
    /// install name.
    private let cacheImages: OrderedDictionary<String, MachOFile>

    /// What the sidebar calls the paired cache's group.
    private let pairedCacheName: String?

    /// What kind of image each image of a bundle or a folder is, by path, as
    /// its header said when it was listed.
    private let fileImageTypes: [String: FileType]

    /// The main executable of every app among the images of a bundle or a
    /// folder, by the app's path. An app here is any bundle whose main
    /// executable is an executable rather than a library — an app, an app
    /// extension, an XPC service: each runs as a process of its own, unlike a
    /// framework.
    private let applicationExecutablePathsByBundlePath: [String: String]

    /// The images of a bundle or a folder that are in no app.
    private let imagePathsOutsideApplications: [String]

    /// Turns the real path of one of the file's images back into the path it
    /// is listed under.
    private let pathRebasing: RuntimeDirectoryImageScanner.PathRebasing

    /// Where the dependencies no image of the file holds are looked for: the
    /// dyld shared cache the file is, or is paired with.
    private let cacheDependencySearchPaths: [DependencySearchPath]

    /// What `dependencySearchPaths(forImageAt:)` answers for the images of a
    /// bundle or a folder, by the outermost app they are in — the empty path
    /// for the images in none.
    @Mutex
    private var dependencySearchPathsByApplicationBundlePath: [String: [DependencySearchPath]] = [:]

    /// The images that define the Objective-C classes asked about so far —
    /// `nil` for a class none of the images exports.
    @Mutex
    private var objcClassImagePaths: [String: String?] = [:]

    /// The file's own image that exports each Objective-C class, by class
    /// name, made the first time a class is looked up: looking a name up image
    /// by image would open every image of a folder for every name.
    @Mutex
    private var fileImagePathsByExportedObjCClassName: [String: String]? = nil

    /// Lists the file's images and opens its paired cache. Throws
    /// `RuntimeOfflineFileError`.
    init(file: RuntimeOfflineFile) throws {
        self.file = file
        var fileImagePaths: [String] = []
        var fileImageTypes: [String: FileType] = [:]
        var openedFileImages: [String: MachOFile] = [:]
        var fileSlice: RuntimeOfflineFile.Slice?
        var cacheImages: OrderedDictionary<String, MachOFile> = [:]
        var pairedCacheName: String?
        var dependencySearchPaths: [DependencySearchPath] = []

        switch file.content {
        case .machO(let slice):
            openedFileImages[file.url.path] = try RuntimeOfflineFile.machOFile(at: file.url, preferring: slice)
            fileImagePaths = [file.url.path]
            fileSlice = slice
        case .bundle, .folder:
            let images = RuntimeDirectoryImageScanner.images(in: file.url)
            fileImagePaths = images.map(\.path)
            fileImageTypes = Dictionary(images.map { ($0.path, $0.fileType) }, uniquingKeysWith: { first, _ in first })
            if case .bundle = file.content {
                Self.moveMainExecutableFirst(ofBundleAt: file.url, in: &fileImagePaths)
            }
            guard !fileImagePaths.isEmpty else {
                throw file.content == .bundle
                    ? RuntimeOfflineFileError.bundleWithoutExecutable(file.url)
                    : RuntimeOfflineFileError.folderWithoutMachOFiles(file.url)
            }
        case .dyldSharedCache:
            let cache: FullDyldCache
            do {
                cache = try FullDyldCache(url: file.url)
            } catch {
                throw RuntimeOfflineFileError.unsupportedContent(file.url)
            }
            cacheImages = Self.images(of: cache)
            dependencySearchPaths.append(.dyldSharedCache(path: file.url.path))
        }

        if file.content != .dyldSharedCache {
            switch file.dependencyCache {
            case .systemDyldSharedCache:
                // The process's one opening of this Mac's cache, which the
                // Swift layout engine's dependency closures read as well.
                // `host` opens and maps all eighty-odd files again each time.
                guard let cache = FullDyldCache.cachedHost else {
                    throw RuntimeOfflineFileError.dependencyCacheUnavailable("this Mac has no dyld shared cache to read")
                }
                cacheImages = Self.images(of: cache)
                pairedCacheName = "Dyld Shared Cache"
                dependencySearchPaths.append(.systemDyldSharedCache)
            case .dyldSharedCache(let cacheURL):
                let cache: FullDyldCache
                do {
                    cache = try FullDyldCache(url: cacheURL)
                } catch {
                    throw RuntimeOfflineFileError.dependencyCacheUnavailable("\(cacheURL.path) is not a dyld shared cache")
                }
                cacheImages = Self.images(of: cache)
                pairedCacheName = "Dyld Shared Cache"
                dependencySearchPaths.append(.dyldSharedCache(path: cacheURL.path))
            case nil:
                break
            }
        }

        let applicationExecutablePathsByBundlePath = Self.applicationExecutablePathsByBundlePath(
            among: fileImagePaths.filter { fileImageTypes[$0] == .execute },
            under: file.url.path
        )
        self.fileImagePaths = fileImagePaths
        self.fileImagePathSet = Set(fileImagePaths)
        self.fileSlice = fileSlice
        self.cacheImages = cacheImages
        self.pairedCacheName = pairedCacheName
        self.fileImageTypes = fileImageTypes
        self.applicationExecutablePathsByBundlePath = applicationExecutablePathsByBundlePath
        self.imagePathsOutsideApplications = fileImagePaths.filter { imagePath in
            Self.applicationBundlePaths(enclosing: imagePath, under: file.url.path, among: applicationExecutablePathsByBundlePath).isEmpty
        }
        self.cacheDependencySearchPaths = dependencySearchPaths
        self.pathRebasing = RuntimeDirectoryImageScanner.PathRebasing(
            directoryPath: file.content == .folder || file.content == .bundle ? file.url.path : file.url.deletingLastPathComponent().path
        )
        self.openedFileImages = openedFileImages
        #log(.info, "Listed \(file.url.path, privacy: .public): \(fileImagePaths.count, privacy: .public) images of its own, \(cacheImages.count, privacy: .public) of a dyld shared cache")
    }

    // MARK: - RuntimeImageCatalog

    func imagePaths() -> [String] {
        fileImagePaths + Array(cacheImages.keys)
    }

    func rootNodes() -> [RuntimeImageNode] {
        switch file.content {
        case .dyldSharedCache:
            return [RuntimeImageNode.rootNode(for: Array(cacheImages.keys), name: file.displayName)]
        case .machO, .bundle, .folder:
            var rootNodes = [RuntimeImageNode.rootNode(for: fileImagePaths, name: file.displayName)]
            if let pairedCacheName {
                rootNodes.append(RuntimeImageNode.rootNode(for: Array(cacheImages.keys), name: pairedCacheName))
            }
            return rootNodes
        }
    }

    /// Paths are the catalog's own keys; nothing rewrites them.
    func canonicalImagePath(_ imagePath: String) -> String {
        imagePath
    }

    /// The listed image the path leads to once `..` and symbolic links are
    /// followed: a framework linked as `@rpath/X.framework/X` from an
    /// executable whose run path is `@executable_path/../Frameworks` resolves
    /// to `…/MacOS/../Frameworks/X.framework/X`, and the file listed is
    /// `…/Frameworks/X.framework/Versions/A/X`.
    func listedImagePath(forResolvedPath resolvedPath: String) -> String {
        guard !fileImagePathSet.contains(resolvedPath), cacheImages[resolvedPath] == nil,
              let realPathPointer = realpath(resolvedPath, nil)
        else { return resolvedPath }
        let listedPath = pathRebasing.rebased(String(cString: realPathPointer))
        free(realPathPointer)
        return fileImagePathSet.contains(listedPath) ? listedPath : resolvedPath
    }

    /// An image of the file is opened here the first time it is asked for;
    /// `nil` when it cannot be opened any more — removed or changed since it
    /// was listed.
    func machO(forImagePath imagePath: String) -> MachOFile? {
        guard fileImagePathSet.contains(imagePath) else {
            return cacheImages[imagePath]
        }
        return _openedFileImages.withLock { openedFileImages in
            if let openedImage = openedFileImages[imagePath] {
                return openedImage
            }
            do {
                let image = try RuntimeOfflineFile.machOFile(at: URL(fileURLWithPath: imagePath), preferring: fileSlice)
                openedFileImages[imagePath] = image
                return image
            } catch {
                #log(.error, "Could not open \(imagePath, privacy: .public): \(error, privacy: .public)")
                return nil
            }
        }
    }

    /// Nothing to load: `machO(forImagePath:)` opens an image when it is
    /// first asked for.
    func prepareImage(at imagePath: String) throws {}

    /// The image exporting the class object, which is how another image links
    /// to it: its own images first, then the cache's. A protocol is exported
    /// by no image, so only an image indexed already can answer for one; see
    /// the offline mode proposal's decision log.
    func image(definingObjCType name: RuntimeObjCName) async -> (imagePath: String, machO: MachOFile)? {
        guard case .class(let className) = name else { return nil }
        if let known = objcClassImagePaths[className] {
            return known.flatMap { imagePath in machO(forImagePath: imagePath).map { (imagePath, $0) } }
        }
        let foundPath = fileImagePath(exportingObjCClassNamed: className)
            ?? cacheImages.first { $0.value.exportTrie?.search(by: Self.objcClassSymbolPrefix + className) != nil }?.key
        objcClassImagePaths[className] = .some(foundPath)
        return foundPath.flatMap { imagePath in machO(forImagePath: imagePath).map { (imagePath, $0) } }
    }

    /// The first of the file's own images: there is nothing to run, so
    /// nothing else stands out. A folder has none: whatever runs there is one
    /// of its several executables.
    func mainExecutablePath() -> String {
        if case .folder = file.content { return "" }
        return fileImagePaths.first ?? ""
    }

    /// For an image of a bundle or a folder: the image itself when it is an
    /// executable, or else the executable of the nearest app it is in — an
    /// app extension's own, not the app's around it. `nil` for an image in no
    /// app, and for a Mach-O file, which is its own walk's main executable.
    func mainExecutablePath(forImageAt imagePath: String) -> String? {
        guard let fileType = fileImageTypes[imagePath] else { return nil }
        if fileType == .execute { return imagePath }
        return applicationBundlePaths(enclosing: imagePath).first.flatMap { applicationExecutablePathsByBundlePath[$0] }
    }

    func isSharedCacheImage(_ path: String) -> Bool {
        cacheImages[path] != nil
    }

    /// An image's own images to stand in for the dependencies it links by
    /// `@rpath` names — which the locator matches by file name, and opens all
    /// of — then the cache's. An image of a bundle or a folder gets the images
    /// of the outermost app it is in, then the images in no app; another app's
    /// never, which would hold frameworks of the same names. A whole `.app`
    /// opened as a bundle is one app: every image gets every other.
    func dependencySearchPaths(forImageAt imagePath: String) -> [DependencySearchPath] {
        switch file.content {
        case .dyldSharedCache:
            return cacheDependencySearchPaths
        case .machO:
            return fileImagePaths.map { DependencySearchPath.machOFile(path: $0) } + cacheDependencySearchPaths
        case .bundle, .folder:
            guard fileImageTypes[imagePath] != nil else { return cacheDependencySearchPaths }
            let applicationBundlePath = applicationBundlePaths(enclosing: imagePath).last ?? ""
            return _dependencySearchPathsByApplicationBundlePath.withLock { searchPathsByApplicationBundlePath in
                if let searchPaths = searchPathsByApplicationBundlePath[applicationBundlePath] {
                    return searchPaths
                }
                let applicationImagePaths = applicationBundlePath.isEmpty ? [] : fileImagePaths.filter { $0.hasPrefix(applicationBundlePath + "/") }
                let searchPaths = (applicationImagePaths + imagePathsOutsideApplications).map { DependencySearchPath.machOFile(path: $0) }
                    + cacheDependencySearchPaths
                searchPathsByApplicationBundlePath[applicationBundlePath] = searchPaths
                return searchPaths
            }
        }
    }

    // MARK: - Exported Objective-C Classes

    private static let objcClassSymbolPrefix = "_OBJC_CLASS_$_"

    /// The file's own image exporting `className`'s class object, the first
    /// in listing order. The first lookup reads every image's exported class
    /// names, opening the images not open yet only for as long as that takes.
    private func fileImagePath(exportingObjCClassNamed className: String) -> String? {
        _fileImagePathsByExportedObjCClassName.withLock { imagePathsByClassName in
            if imagePathsByClassName == nil {
                imagePathsByClassName = makeImagePathsByExportedObjCClassName()
            }
            return imagePathsByClassName?[className]
        }
    }

    private func makeImagePathsByExportedObjCClassName() -> [String: String] {
        var classNamesByImageIndex = Array(repeating: [String](), count: fileImagePaths.count)
        classNamesByImageIndex.withUnsafeMutableBufferPointer { classNamesByImageIndex in
            DispatchQueue.concurrentPerform(iterations: fileImagePaths.count) { index in
                let imagePath = fileImagePaths[index]
                let image = openedFileImages[imagePath]
                    ?? (try? RuntimeOfflineFile.machOFile(at: URL(fileURLWithPath: imagePath), preferring: fileSlice))
                classNamesByImageIndex[index] = (image?.exportTrie?.search(byKeyPrefix: Self.objcClassSymbolPrefix) ?? []).map { symbol in
                    symbol.name.hasPrefix(Self.objcClassSymbolPrefix) ? String(symbol.name.dropFirst(Self.objcClassSymbolPrefix.count)) : symbol.name
                }
            }
        }
        var imagePathsByClassName: [String: String] = [:]
        for (index, classNames) in classNamesByImageIndex.enumerated() {
            for className in classNames where imagePathsByClassName[className] == nil {
                imagePathsByClassName[className] = fileImagePaths[index]
            }
        }
        #log(.info, "Indexed the Objective-C classes \(self.fileImagePaths.count, privacy: .public) images export: \(imagePathsByClassName.count, privacy: .public)")
        return imagePathsByClassName
    }

    // MARK: - Listing

    /// Every image of a dyld shared cache, by install name, in the cache's
    /// order.
    private static func images(of cache: FullDyldCache) -> OrderedDictionary<String, MachOFile> {
        var images: OrderedDictionary<String, MachOFile> = [:]
        for machOFile in cache.machOFiles() where images[machOFile.imagePath] == nil {
            images[machOFile.imagePath] = machOFile
        }
        return images
    }

    /// Puts a bundle's main executable before its other images.
    private static func moveMainExecutableFirst(ofBundleAt bundleURL: URL, in imagePaths: inout [String]) {
        guard let executablePath = Bundle(url: bundleURL)?.executableURL?.standardizedFileURL.resolvingSymlinksInPath().path,
              let executableIndex = imagePaths.firstIndex(of: executablePath)
        else { return }
        imagePaths.insert(imagePaths.remove(at: executableIndex), at: 0)
    }

    // MARK: - Apps

    /// The apps the executables at `executablePaths` are the main executables
    /// of, by the app's path, each with its executable. Only directories at or
    /// below `rootPath` count.
    private static func applicationExecutablePathsByBundlePath(among executablePaths: [String], under rootPath: String) -> [String: String] {
        var executablePathsByBundlePath: [String: String] = [:]
        for executablePath in executablePaths {
            guard let bundlePath = bundlePath(ofMainExecutableAt: executablePath, under: rootPath),
                  executablePathsByBundlePath[bundlePath] == nil
            else { continue }
            executablePathsByBundlePath[bundlePath] = executablePath
        }
        return executablePathsByBundlePath
    }

    /// The bundle whose main executable `executablePath` is, when it is one:
    /// `Foo.app` for `Foo.app/Contents/MacOS/Foo`, or for the `Foo.app/Foo`
    /// of an app without a `Contents` directory, as iOS lays apps out. The
    /// bundle's `Info.plist` has to name the executable.
    private static func bundlePath(ofMainExecutableAt executablePath: String, under rootPath: String) -> String? {
        let executableURL = URL(fileURLWithPath: executablePath)
        let executableDirectoryURL = executableURL.deletingLastPathComponent()
        var candidates: [(bundleURL: URL, infoPropertyListURL: URL)] = [
            (executableDirectoryURL, executableDirectoryURL.appendingPathComponent("Info.plist")),
        ]
        if executableDirectoryURL.lastPathComponent == "MacOS",
           executableDirectoryURL.deletingLastPathComponent().lastPathComponent == "Contents" {
            let contentsURL = executableDirectoryURL.deletingLastPathComponent()
            candidates.insert((contentsURL.deletingLastPathComponent(), contentsURL.appendingPathComponent("Info.plist")), at: 0)
        }
        for candidate in candidates {
            let bundlePath = candidate.bundleURL.path
            guard bundlePath == rootPath || bundlePath.hasPrefix(rootPath + "/"),
                  let propertyListData = try? Data(contentsOf: candidate.infoPropertyListURL),
                  let propertyList = try? PropertyListSerialization.propertyList(from: propertyListData, format: nil) as? [String: Any],
                  propertyList["CFBundleExecutable"] as? String == executableURL.lastPathComponent
            else { continue }
            return bundlePath
        }
        return nil
    }

    /// The apps `imagePath` is in, nearest first.
    private func applicationBundlePaths(enclosing imagePath: String) -> [String] {
        Self.applicationBundlePaths(enclosing: imagePath, under: file.url.path, among: applicationExecutablePathsByBundlePath)
    }

    private static func applicationBundlePaths(enclosing imagePath: String, under rootPath: String, among applicationExecutablePathsByBundlePath: [String: String]) -> [String] {
        guard !applicationExecutablePathsByBundlePath.isEmpty else { return [] }
        var bundlePaths: [String] = []
        var directoryPath = (imagePath as NSString).deletingLastPathComponent
        while directoryPath.count >= rootPath.count {
            if applicationExecutablePathsByBundlePath[directoryPath] != nil {
                bundlePaths.append(directoryPath)
            }
            let parentPath = (directoryPath as NSString).deletingLastPathComponent
            guard parentPath != directoryPath else { break }
            directoryPath = parentPath
        }
        return bundlePaths
    }
}
