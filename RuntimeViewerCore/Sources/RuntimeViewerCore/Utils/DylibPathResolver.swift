import Foundation
import FoundationToolbox

@Loggable
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
            var attempts: [String] = []
            for rpath in rpaths {
                let expanded = expand(rpath, imagePath: imagePath,
                                      mainExecutablePath: mainExecutablePath)
                let candidate = expanded + "/" + tail
                let exists = pathExists(candidate)
                attempts.append("[rpath=\(rpath) expanded=\(expanded) candidate=\(candidate) exists=\(exists)]")
                if exists {
                    return candidate
                }
            }
            let attemptsLine = attempts.joined(separator: " ")
            let rpathsLine = rpaths.joined(separator: ", ")
            #log(.error, "@rpath unresolved | installName=\(installName, privacy: .public) | imagePath=\(imagePath, privacy: .public) | mainExecutablePath=\(mainExecutablePath, privacy: .public) | rpaths=[\(rpathsLine, privacy: .public)] | attempts=\(attemptsLine, privacy: .public)")
            return nil
        }
        if installName.hasPrefix("@executable_path/") {
            let tail = String(installName.dropFirst("@executable_path/".count))
            let candidate = (mainExecutablePath as NSString)
                .deletingLastPathComponent + "/" + tail
            let exists = pathExists(candidate)
            if !exists {
                #log(.error, "@executable_path unresolved | installName=\(installName, privacy: .public) | mainExecutablePath=\(mainExecutablePath, privacy: .public) | candidate=\(candidate, privacy: .public)")
            }
            return exists ? candidate : nil
        }
        if installName.hasPrefix("@loader_path/") {
            let tail = String(installName.dropFirst("@loader_path/".count))
            let candidate = (imagePath as NSString)
                .deletingLastPathComponent + "/" + tail
            let exists = pathExists(candidate)
            if !exists {
                #log(.error, "@loader_path unresolved | installName=\(installName, privacy: .public) | imagePath=\(imagePath, privacy: .public) | candidate=\(candidate, privacy: .public)")
            }
            return exists ? candidate : nil
        }
        let exists = pathExists(installName)
        if !exists {
            #log(.error, "absolute path unresolved | installName=\(installName, privacy: .public)")
        }
        return exists ? installName : nil
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
