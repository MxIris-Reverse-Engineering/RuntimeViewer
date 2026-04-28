import Foundation

struct DylibPathResolver {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Resolves a dylib install name to a concrete filesystem path.
    /// Returns nil when the resolved path does not exist.
    func resolve(installName: String,
                 imagePath: String,
                 rpaths: [String],
                 mainExecutablePath: String) -> String? {
        if installName.hasPrefix("@rpath/") {
            let tail = String(installName.dropFirst("@rpath/".count))
            for rpath in rpaths {
                let candidate = expand(rpath, imagePath: imagePath,
                                       mainExecutablePath: mainExecutablePath)
                    + "/" + tail
                if pathExists(candidate) {
                    return candidate
                }
            }
            return nil
        }
        if installName.hasPrefix("@executable_path/") {
            let tail = String(installName.dropFirst("@executable_path/".count))
            let candidate = (mainExecutablePath as NSString)
                .deletingLastPathComponent + "/" + tail
            return pathExists(candidate) ? candidate : nil
        }
        if installName.hasPrefix("@loader_path/") {
            let tail = String(installName.dropFirst("@loader_path/".count))
            let candidate = (imagePath as NSString)
                .deletingLastPathComponent + "/" + tail
            return pathExists(candidate) ? candidate : nil
        }
        return pathExists(installName) ? installName : nil
    }

    /// True when `path` is either an on-disk file OR an image baked into the
    /// dyld shared cache. Apple Silicon ships system frameworks (Foundation,
    /// UIKit, libobjc, libSystem, ...) inside the cache with no backing file,
    /// so a pure `FileManager.fileExists` check rejects them as unresolved.
    private func pathExists(_ path: String) -> Bool {
        if fileManager.fileExists(atPath: path) { return true }
        if DyldUtilities.isInDyldSharedCache(path) { return true }
        return false
    }

    private func expand(_ rpath: String,
                        imagePath: String,
                        mainExecutablePath: String) -> String {
        if rpath.hasPrefix("@executable_path/") {
            let tail = String(rpath.dropFirst("@executable_path/".count))
            return (mainExecutablePath as NSString)
                .deletingLastPathComponent + "/" + tail
        }
        if rpath.hasPrefix("@loader_path/") {
            let tail = String(rpath.dropFirst("@loader_path/".count))
            return (imagePath as NSString)
                .deletingLastPathComponent + "/" + tail
        }
        return rpath
    }
}
