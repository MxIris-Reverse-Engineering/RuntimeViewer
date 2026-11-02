import Foundation
import FoundationToolbox
import MachOKit
import MachODependencies
import OrderedCollections

/// The images of a file on disk — a Mach-O file, a bundle or a dyld shared
/// cache — and of the dyld shared cache it is paired with, read as `MachOFile`s.
///
/// What the offline engine reads. Every image is opened when the catalog is
/// made, so a path either names one of them or nothing; no image is run.
/// The images of the file itself are keyed by their paths on disk, those of a
/// dyld shared cache by their install names, which is how the cache lists them.
@Loggable(.private)
final class RuntimeFileImageCatalog: RuntimeImageCatalog, @unchecked Sendable {
    typealias Reading = RuntimeFileImageReading

    let file: RuntimeOfflineFile

    /// The images of the file itself, by path on disk, the main executable
    /// first: one for a Mach-O file, every Mach-O file inside a bundle, none
    /// for a dyld shared cache.
    private let fileImages: OrderedDictionary<String, MachOFile>

    /// The images of the dyld shared cache the file is, or is paired with, by
    /// install name.
    private let cacheImages: OrderedDictionary<String, MachOFile>

    /// What the sidebar calls the paired cache's group.
    private let pairedCacheName: String?

    private let dependencySearchPathList: [DependencySearchPath]

    /// The images that define the Objective-C classes asked about so far —
    /// `nil` for a class none of the images exports.
    @Mutex
    private var objcClassImagePaths: [String: String?] = [:]

    /// Opens the file and its paired cache. Throws `RuntimeOfflineFileError`.
    init(file: RuntimeOfflineFile) throws {
        self.file = file
        var fileImages: OrderedDictionary<String, MachOFile> = [:]
        var cacheImages: OrderedDictionary<String, MachOFile> = [:]
        var pairedCacheName: String?
        var dependencySearchPaths: [DependencySearchPath] = []

        switch file.content {
        case .machO(let slice):
            fileImages[file.url.path] = try RuntimeOfflineFile.machOFile(at: file.url, preferring: slice)
        case .bundle:
            fileImages = Self.bundleImages(of: file.url)
            guard !fileImages.isEmpty else {
                throw RuntimeOfflineFileError.bundleWithoutExecutable(file.url)
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
            // Every image of the file can stand in for a dependency of
            // another: a bundle's frameworks are linked by `@rpath` names the
            // locator matches by file name.
            dependencySearchPaths.append(contentsOf: fileImages.keys.map { DependencySearchPath.machOFile(path: $0) })
            switch file.dependencyCache {
            case .systemDyldSharedCache:
                guard let cache = FullDyldCache.host else {
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

        self.fileImages = fileImages
        self.cacheImages = cacheImages
        self.pairedCacheName = pairedCacheName
        self.dependencySearchPathList = dependencySearchPaths
        #log(.info, "Opened \(file.url.path, privacy: .public): \(fileImages.count, privacy: .public) images of its own, \(cacheImages.count, privacy: .public) of a dyld shared cache")
    }

    // MARK: - RuntimeImageCatalog

    func imagePaths() -> [String] {
        Array(fileImages.keys) + Array(cacheImages.keys)
    }

    func rootNodes() -> [RuntimeImageNode] {
        switch file.content {
        case .dyldSharedCache:
            return [RuntimeImageNode.rootNode(for: Array(cacheImages.keys), name: file.displayName)]
        case .machO, .bundle:
            var rootNodes = [RuntimeImageNode.rootNode(for: Array(fileImages.keys), name: file.displayName)]
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

    func machO(forImagePath imagePath: String) -> MachOFile? {
        fileImages[imagePath] ?? cacheImages[imagePath]
    }

    /// Nothing to load: every image was opened with the catalog.
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
        let symbolName = "_OBJC_CLASS_$_" + className
        let found = (Array(fileImages.elements) + Array(cacheImages.elements)).first { image in
            image.value.exportTrie?.search(by: symbolName) != nil
        }
        objcClassImagePaths[className] = .some(found?.key)
        return found.map { ($0.key, $0.value) }
    }

    func mainExecutablePath() -> String {
        fileImages.keys.first ?? ""
    }

    func isSharedCacheImage(_ path: String) -> Bool {
        cacheImages[path] != nil
    }

    var dependencySearchPaths: [DependencySearchPath] {
        dependencySearchPathList
    }

    // MARK: - Opening

    /// Every image of a dyld shared cache, by install name, in the cache's
    /// order.
    private static func images(of cache: FullDyldCache) -> OrderedDictionary<String, MachOFile> {
        var images: OrderedDictionary<String, MachOFile> = [:]
        for machOFile in cache.machOFiles() where images[machOFile.imagePath] == nil {
            images[machOFile.imagePath] = machOFile
        }
        return images
    }

    /// Every Mach-O file inside a bundle, by path on disk, its main executable
    /// first. Symbolic links are skipped — a framework's `Versions/Current`
    /// would list each binary twice — and a fat file contributes the slice
    /// this Mac prefers.
    private static func bundleImages(of bundleURL: URL) -> OrderedDictionary<String, MachOFile> {
        var images: OrderedDictionary<String, MachOFile> = [:]
        if let executableURL = Bundle(url: bundleURL)?.executableURL?.standardizedFileURL.resolvingSymlinksInPath(),
           let executable = try? RuntimeOfflineFile.machOFile(at: executableURL, preferring: nil) {
            images[executableURL.path] = executable
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: bundleURL, includingPropertiesForKeys: keys) else {
            return images
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true, values.isSymbolicLink != true
            else { continue }
            let path = fileURL.standardizedFileURL.path
            guard images[path] == nil, Self.startsWithMachOMagic(fileURL),
                  let machOFile = try? RuntimeOfflineFile.machOFile(at: fileURL, preferring: nil)
            else { continue }
            images[path] = machOFile
        }
        return images
    }

    private static func startsWithMachOMagic(_ fileURL: URL) -> Bool {
        guard let fileHandle = try? FileHandle(forReadingFrom: fileURL) else { return false }
        defer { try? fileHandle.close() }
        guard let bytes = try? fileHandle.read(upToCount: 4), bytes.count == 4 else { return false }
        let magic = Array(bytes)
        return magic == [0xCF, 0xFA, 0xED, 0xFE] || magic == [0xCE, 0xFA, 0xED, 0xFE]
            || magic == [0xCA, 0xFE, 0xBA, 0xBE] || magic == [0xCA, 0xFE, 0xBA, 0xBF]
    }
}
