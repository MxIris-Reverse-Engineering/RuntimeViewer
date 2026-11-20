import Foundation
import FoundationToolbox

@Loggable
struct DylibPathResolver {
    private let fileManager: FileManager

    /// Whether a path that names no file on disk is an image of the dyld
    /// shared cache the images being resolved come from: this process's cache
    /// for images dyld loaded, the cache a file is paired with for
    /// one read from disk.
    private let isSharedCacheImage: @Sendable (String) -> Bool

    init(
        fileManager: FileManager = .default,
        isSharedCacheImage: @escaping @Sendable (String) -> Bool = { DyldUtilities.isInDyldSharedCache($0) }
    ) {
        self.fileManager = fileManager
        self.isSharedCacheImage = isSharedCacheImage
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

    /// One `LC_RPATH` on dyld's rpath stack, with the image that carries it.
    struct RpathStackEntry: Sendable, Hashable {
        var rpath: String
        var ownerImagePath: String
        var role: RuntimeImageLoadDiagnosis.RpathSearch.Role
    }

    /// One place a load name was looked for.
    struct Attempt: Sendable, Hashable {
        /// The rpath that produced the candidate; `nil` when the load name is
        /// a path of its own (`@loader_path/…`, `@executable_path/…`, absolute).
        var entry: RpathStackEntry?
        var candidatePath: String
        var exists: Bool
    }

    struct Resolution: Sendable, Hashable {
        var resolvedPath: String?
        var attempts: [Attempt]
    }

    /// Resolves `installName`, which the image at `imagePath` links, the way
    /// dyld searches for it, and records every place it looked.
    ///
    /// `rpathStack` is in dyld's search order: the loading image's own rpaths
    /// first, then each image that loaded it back to the image that called
    /// `dlopen`, then the main executable's (dyld-1323, `Loader.cpp`, the
    /// `@rpath` expansion walks the load chain from its newest link). Unlike
    /// `resolve(installName:imagePath:rpaths:mainExecutablePath:)`, an rpath
    /// that starts at `@loader_path` expands against the image that carries
    /// it, as dyld expands it; a relative rpath is skipped, as dyld skips it.
    func resolution(
        of installName: String,
        loadedBy imagePath: String,
        rpathStack: [RpathStackEntry],
        mainExecutablePath: String
    ) -> Resolution {
        var loadName = installName
        // dyld treats a bare relative load name as an implicit `@rpath/`.
        if !loadName.hasPrefix("@"), !loadName.hasPrefix("/") {
            loadName = "@rpath/" + loadName
        }
        if loadName.hasPrefix("@rpath/") {
            let tail = String(loadName.dropFirst("@rpath/".count))
            var attempts: [Attempt] = []
            for entry in rpathStack {
                guard entry.rpath.hasPrefix("@") || entry.rpath.hasPrefix("/") else { continue }
                let expanded = expand(entry.rpath, imagePath: entry.ownerImagePath, mainExecutablePath: mainExecutablePath)
                let candidate = Self.joined(expanded, tail)
                let exists = pathExists(candidate)
                attempts.append(Attempt(entry: entry, candidatePath: candidate, exists: exists))
                if exists {
                    return Resolution(resolvedPath: candidate, attempts: attempts)
                }
            }
            return Resolution(resolvedPath: nil, attempts: attempts)
        }
        let candidate: String
        if loadName.hasPrefix("@executable_path/") {
            candidate = Self.joined(
                (mainExecutablePath as NSString).deletingLastPathComponent,
                String(loadName.dropFirst("@executable_path/".count))
            )
        } else if loadName.hasPrefix("@loader_path/") {
            candidate = Self.joined(
                (imagePath as NSString).deletingLastPathComponent,
                String(loadName.dropFirst("@loader_path/".count))
            )
        } else {
            candidate = loadName
        }
        let exists = pathExists(candidate)
        return Resolution(resolvedPath: exists ? candidate : nil, attempts: [Attempt(entry: nil, candidatePath: candidate, exists: exists)])
    }

    /// `directory` and `tail` joined by one slash, with `..` and `.` taken out
    /// the way the file system would.
    private static func joined(_ directory: String, _ tail: String) -> String {
        let path = directory.hasSuffix("/") ? directory + tail : directory + "/" + tail
        return URL(fileURLWithPath: path).standardized.path
    }

    /// True when `path` is either an on-disk file OR an image baked into the
    /// dyld shared cache. Apple Silicon ships system frameworks (Foundation,
    /// UIKit, libobjc, libSystem, ...) inside the cache with no backing file,
    /// so a pure `FileManager.fileExists` check rejects them as unresolved.
    private func pathExists(_ path: String) -> Bool {
        if fileManager.fileExists(atPath: path) { return true }
        if isSharedCacheImage(path) { return true }
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
