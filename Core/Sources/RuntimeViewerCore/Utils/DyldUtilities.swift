import MachO.dyld
import MachOKit
import DyldPrivate
package import Foundation

public struct DyldOpenError: Error {
    public let message: String?
}

package enum DyldUtilities {
    package static let addImageNotification = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")

    package static let removeImageNotification = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")

    package static func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    package static func observeDyldRegisterEvents() {
        _dyld_register_func_for_add_image { _, _ in
            NotificationCenter.default.post(name: Self.addImageNotification, object: nil)
        }

        _dyld_register_func_for_remove_image { _, _ in
            NotificationCenter.default.post(name: Self.removeImageNotification, object: nil)
        }
    }

    package static func imageNames() -> [String] {
        (0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) }
    }

    package func imagePath(for ptr: UnsafeRawPointer) -> String? {
        var info: Dl_info = .init()
        dladdr(ptr, &info)
        guard let imagePath = info.dli_fname.map({ String(cString: $0) }) else { return nil }
        return imagePath
    }
    
    package static func loadImage(at path: String) throws {
        try path.withCString { cString in
            let handle = dlopen(cString, RTLD_LAZY)
            // get the error and copy it into an object we control since the error is shared
            let errPtr = dlerror()
            let errStr = errPtr.map { String(cString: $0) }
            guard handle != nil else {
                throw DyldOpenError(message: errStr)
            }
        }
    }

    private static var dyldSharedCacheImagePathsCache: [String]?
    
    private static func dyldSharedCacheImagePaths() -> [String] {
        if let dyldSharedCacheImagePathsCache { return dyldSharedCacheImagePathsCache }
        guard let dyldCache = DyldCacheLoaded.current, let imageInfos = dyldCache.imageInfos else { return [] }
        let results = imageInfos.compactMap { $0.path(in: dyldCache) }
        dyldSharedCacheImagePathsCache = results
        return results
    }
    
    package static func invalidDyldSharedCacheImagePathsCache() {
        dyldSharedCacheImagePathsCache = nil
    }
    
    package static var dyldSharedCacheImageRootNode: RuntimeImageNode {
        return .rootNode(for: dyldSharedCacheImagePaths(), name: "Dyld Shared Cache")
    }

    package static var otherImageRootNode: RuntimeImageNode {
        let dyldSharedCacheImagePaths = dyldSharedCacheImagePaths()
        let allImagePaths = imageNames()
        let otherImagePaths = allImagePaths.filter { !dyldSharedCacheImagePaths.contains($0) }
        return .rootNode(for: otherImagePaths, name: "Others")
    }
}
