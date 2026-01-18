import DyldPrivate
package import Foundation
import FoundationToolbox
import MachO.dyld
import MachOKit
import OSLog

public struct DyldOpenError: Error {
    public let message: String?
}

package enum DyldUtilities: Loggable {
    package static let addImageNotification = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")

    package static let removeImageNotification = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")

    package static func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    package static func observeDyldRegisterEvents() {
        logger.info("Registering dyld image event observers")
        _dyld_register_func_for_add_image { _, _ in
            NotificationCenter.default.post(name: Self.addImageNotification, object: nil)
        }

        _dyld_register_func_for_remove_image { _, _ in
            NotificationCenter.default.post(name: Self.removeImageNotification, object: nil)
        }
        logger.debug("Dyld event observers registered")
    }

    package static func imageNames() -> [String] {
        let names = Array((0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) })
        logger.debug("Retrieved \(names.count, privacy: .public) image names from dyld")
        return names
    }

    package func imagePath(for ptr: UnsafeRawPointer) -> String? {
        var info: Dl_info = .init()
        dladdr(ptr, &info)
        guard let imagePath = info.dli_fname.map({ String(cString: $0) }) else { return nil }
        return imagePath
    }
    
    package static func loadImage(at path: String) throws {
        logger.info("Loading image at path: \(path, privacy: .public)")
        try path.withCString { cString in
            let handle = dlopen(cString, RTLD_LAZY)
            // get the error and copy it into an object we control since the error is shared
            let errPtr = dlerror()
            let errStr = errPtr.map { String(cString: $0) }
            guard handle != nil else {
                logger.error("Failed to load image: \(errStr ?? "unknown error", privacy: .public)")
                throw DyldOpenError(message: errStr)
            }
            logger.info("Image loaded successfully")
        }
    }

    private static var dyldSharedCacheImagePathsCache: [String]?
    
    private static func dyldSharedCacheImagePaths() -> [String] {
        if let dyldSharedCacheImagePathsCache {
            logger.debug("Using cached dyld shared cache image paths (\(dyldSharedCacheImagePathsCache.count, privacy: .public) paths)")
            return dyldSharedCacheImagePathsCache
        }
        logger.debug("Loading dyld shared cache image paths")
        guard let dyldCache = DyldCacheLoaded.current, let imageInfos = dyldCache.imageInfos else {
            logger.warning("Failed to load dyld shared cache or image infos")
            return []
        }
        let results = imageInfos.compactMap { $0.path(in: dyldCache) }
        dyldSharedCacheImagePathsCache = results
        logger.info("Loaded \(results.count, privacy: .public) dyld shared cache image paths")
        return results
    }

    package static func invalidDyldSharedCacheImagePathsCache() {
        logger.debug("Invalidating dyld shared cache image paths cache")
        dyldSharedCacheImagePathsCache = nil
    }

    package static var dyldSharedCacheImageRootNode: RuntimeImageNode {
        logger.debug("Building dyld shared cache image root node")
        let paths = dyldSharedCacheImagePaths()
        let node = RuntimeImageNode.rootNode(for: paths, name: "Dyld Shared Cache")
        logger.debug("Built dyld shared cache root node with \(paths.count, privacy: .public) images")
        return node
    }

    package static var otherImageRootNode: RuntimeImageNode {
        logger.debug("Building other image root node")
        let dyldSharedCacheImagePaths = dyldSharedCacheImagePaths()
        let allImagePaths = imageNames()
        let otherImagePaths = allImagePaths.filter { !dyldSharedCacheImagePaths.contains($0) }
        let node = RuntimeImageNode.rootNode(for: otherImagePaths, name: "Others")
        logger.debug("Built other images root node with \(otherImagePaths.count, privacy: .public) images")
        return node
    }
}
