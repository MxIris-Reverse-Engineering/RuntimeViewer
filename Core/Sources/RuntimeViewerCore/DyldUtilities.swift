import Foundation

public struct DyldOpenError: Error {
    public let message: String?
}

package enum DyldUtilities {
    package static func patchImagePathForDyld(_ imagePath: String) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        let rootPath = ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        guard let rootPath else { return imagePath }
        return rootPath.appending(imagePath)
    }

    package static func imageNames() -> [String] {
        (0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) }
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

    package static var dyldSharedCacheImageRootNode: RuntimeNamedNode {
        return .rootNode(for: CDUtilities.dyldSharedCacheImagePaths(), name: "Dyld Shared Cache")
    }

    package static var otherImageRootNode: RuntimeNamedNode {
        let dyldSharedCacheImagePaths = CDUtilities.dyldSharedCacheImagePaths()
        let allImagePaths = imageNames()
        let otherImagePaths = allImagePaths.filter { !dyldSharedCacheImagePaths.contains($0) }
        return .rootNode(for: otherImagePaths, name: "Others")
    }
}
