package import Foundation
import FoundationToolbox
import MachO.dyld
package import MachOKit

public struct DyldOpenError: Error {
    public let message: String?
}

@Loggable
package enum DyldUtilities {
    package static let addImageNotification = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.addImageNotification")

    package static let removeImageNotification = Notification.Name("com.JH.RuntimeViewerCore.DyldRegisterObserver.removeImageNotification")

    package static func patchImagePathForDyld(_ imagePath: String) -> String {
        patchImagePathForDyld(
            imagePath,
            rootPath: ProcessInfo.processInfo.environment["DYLD_ROOT_PATH"]
        )
    }

    /// Pure overload that takes the dyld root path explicitly so callers
    /// (and tests) can drive the patching logic without touching process env.
    ///
    /// Idempotent: calling repeatedly with the same `rootPath` returns the
    /// same string after the first invocation. This matters because dyld
    /// reports already-patched paths in simulator runners — re-patching them
    /// would produce a doubled prefix like `/sim_root/sim_root/usr/lib/...`.
    package static func patchImagePathForDyld(_ imagePath: String, rootPath: String?) -> String {
        guard imagePath.starts(with: "/") else { return imagePath }
        guard let rootPath else { return imagePath }
        if imagePath == rootPath || imagePath.hasPrefix(rootPath + "/") {
            return imagePath
        }
        return rootPath.appending(imagePath)
    }

    package static func observeDyldRegisterEvents() {
        #log(.info, "Registering dyld image event observers")
        _dyld_register_func_for_add_image { _, _ in
            NotificationCenter.default.post(name: Self.addImageNotification, object: nil)
        }

        _dyld_register_func_for_remove_image { _, _ in
            NotificationCenter.default.post(name: Self.removeImageNotification, object: nil)
        }
        #log(.debug, "Dyld event observers registered")
    }

    package static func imageNames() -> [String] {
        let names = Array((0...)
            .lazy
            .map(_dyld_get_image_name)
            .prefix { $0 != nil }
            .compactMap { $0 }
            .map { String(cString: $0) })
        #log(.debug, "Retrieved \(names.count, privacy: .public) image names from dyld")
        return names
    }

    /// Path of the host process's main executable.
    ///
    /// Uses `_NSGetExecutablePath()` rather than `imageNames().first` because
    /// dyld image index 0 is **not** guaranteed to be the host executable when
    /// the process was launched with `DYLD_INSERT_LIBRARIES`. Xcode injects
    /// `/Applications/Xcode.app/Contents/Developer/usr/lib/libLogRedirect.dylib`
    /// during debug runs and that dylib lands at index 0, so `imageNames().first`
    /// returns Xcode's helper instead of the app binary. Downstream uses
    /// (BFS root path, `@executable_path/...` rpath expansion) need the real
    /// executable or every `@rpath/...` resolves against Xcode's directory and
    /// gets reported as `path unresolved`.
    package static func mainExecutablePath() -> String {
        var bufSize: UInt32 = 1024
        var buf = [CChar](repeating: 0, count: Int(bufSize))
        if _NSGetExecutablePath(&buf, &bufSize) == 0 {
            return String(cString: buf)
        }
        // bufSize was too small. _NSGetExecutablePath wrote the required size
        // back into `bufSize`; allocate accordingly and retry.
        buf = [CChar](repeating: 0, count: Int(bufSize))
        if _NSGetExecutablePath(&buf, &bufSize) == 0 {
            return String(cString: buf)
        }
        // Last-resort fallback. Won't happen in practice, but better than
        // returning "" — `@executable_path` expansion downstream prefers an
        // imperfect path over an empty one.
        return imageNames().first ?? ""
    }

    /// Resolves a filesystem path to its loaded `MachOImage`.
    ///
    /// Three lookup tiers, in order:
    ///
    /// 1. **Debug-stub → `.debug.dylib` redirect.** In Debug builds Xcode
    ///    emits the main executable as a thin stub at `Contents/MacOS/<Name>`
    ///    plus a sibling `<Name>.debug.dylib` that holds all sections,
    ///    classes, and dependencies; dyld registers BOTH paths and `_NSGet`
    ///    `ExecutablePath` returns the stub. A naive exact-match on the stub
    ///    path returns the stub's tiny `MachOImage` (whose `LC_LOAD_DYLIB` is
    ///    just `@rpath/<Name>.debug.dylib` + `/usr/lib/libSystem.B.dylib`),
    ///    so any dependency BFS rooted at the main executable can't reach
    ///    AppKit / the app's actual framework graph. When the requested path
    ///    matches `mainExecutablePath()` AND dyld has a sibling
    ///    `<path>.debug.dylib` loaded, return that image instead. The dyld
    ///    membership check keeps this safe in the injected-server scenario:
    ///    `mainExecutablePath()` then names the *target* process's main
    ///    binary, and the redirect lands on the target's own `.debug.dylib`
    ///    (correct) — not on our framework's image (which is what an
    ///    unconditional `MachOImage.current()` would return).
    ///
    /// 2. **Exact dyld path match.** Walks every image dyld currently has
    ///    loaded and returns the one whose registered path equals `path`
    ///    byte-for-byte. This is the correct answer for non-stub injection
    ///    scenarios: when this code is dlopen'd into a foreign process,
    ///    `#dsohandle` lands inside `RuntimeViewerServer.framework`, so
    ///    `MachOImage.current()` would return the framework itself instead
    ///    of the target's main binary. dyld's own image registry doesn't lie.
    ///
    /// 3. **Basename match.** Last-resort fuzzy lookup for callers that pass
    ///    a path whose exact spelling doesn't match dyld's registered form
    ///    (e.g. symlink-resolved vs. raw, or a bare framework name).
    package static func machOImage(forPath path: String) -> MachOImage? {
        if let exact = exactMachOImage(forPath: path) {
            return exact
        }
        let imageName = path.lastPathComponent.deletingPathExtension.deletingPathExtension
        return MachOImage(name: imageName)
    }

    /// Resolves a filesystem path to a loaded `MachOImage` without basename
    /// fallback.
    ///
    /// Export metadata must use exact matching only: when inspecting a remote
    /// iOS simulator image from the macOS app process, a fuzzy basename match
    /// can accidentally pick the host's same-named framework.
    package static func exactMachOImage(forPath path: String) -> MachOImage? {
        if path == mainExecutablePath(),
           let debugDylib = loadedImage(forExactPath: path + ".debug.dylib") {
            return debugDylib
        }
        return loadedImage(forExactPath: path)
    }

    /// Returns the loaded `MachOImage` whose dyld-registered path equals
    /// `path` byte-for-byte, or `nil` if no such image is loaded.
    private static func loadedImage(forExactPath path: String) -> MachOImage? {
        for index in 0..<_dyld_image_count() {
            guard let cName = _dyld_get_image_name(index),
                  let header = _dyld_get_image_header(index) else { continue }
            if String(cString: cName) == path {
                return MachOImage(ptr: header)
            }
        }
        return nil
    }

    package func imagePath(for ptr: UnsafeRawPointer) -> String? {
        var info: Dl_info = .init()
        dladdr(ptr, &info)
        guard let imagePath = info.dli_fname.map({ String(cString: $0) }) else { return nil }
        return imagePath
    }
    
    package static func loadImage(at path: String) throws {
        #log(.info, "Loading image at path: \(path, privacy: .public)")
        try path.withCString { cString in
            let handle = dlopen(cString, RTLD_LAZY)
            // get the error and copy it into an object we control since the error is shared
            let errPtr = dlerror()
            let errStr = errPtr.map { String(cString: $0) }
            guard handle != nil else {
                #log(.error, "Failed to load image: \(errStr ?? "unknown error", privacy: .public)")
                throw DyldOpenError(message: errStr)
            }
            #log(.info, "Image loaded successfully")
        }
    }

    private static var dyldSharedCacheImagePathsCache: [String]?
    private static var dyldSharedCacheImagePathsSetCache: Set<String>?

    private static func dyldSharedCacheImagePaths() -> [String] {
        if let dyldSharedCacheImagePathsCache {
            #log(.debug, "Using cached dyld shared cache image paths (\(dyldSharedCacheImagePathsCache.count, privacy: .public) paths)")
            return dyldSharedCacheImagePathsCache
        }
        #log(.debug, "Loading dyld shared cache image paths")
        guard let dyldCache = DyldCacheLoaded.current, let imageInfos = dyldCache.imageInfos else {
            #log(.default, "Failed to load dyld shared cache or image infos")
            return []
        }
        let results = imageInfos.compactMap { $0.path(in: dyldCache) }
        dyldSharedCacheImagePathsCache = results
        #log(.info, "Loaded \(results.count, privacy: .public) dyld shared cache image paths")
        return results
    }

    /// Whether `path` corresponds to an image baked into the dyld shared cache.
    ///
    /// On Apple Silicon (and recent Intel macOS), system dylibs like
    /// `/usr/lib/libobjc.A.dylib` have **no on-disk file** ——
    /// `FileManager.fileExists` returns `false` for them. Callers that need
    /// to validate "does this image really exist" must check both the
    /// filesystem and this set.
    ///
    /// Lookup is by literal equality against the cache's stored paths. The
    /// cache stores the platform-native form (`Foundation.framework/Versions/C/Foundation`
    /// on macOS, `Foundation.framework/Foundation` on iOS); install names that
    /// use a different form fall through to a real "path unresolved" failure
    /// rather than being silently rewritten.
    package static func isInDyldSharedCache(_ path: String) -> Bool {
        return dyldSharedCacheImagePathsSet().contains(path)
    }

    private static func dyldSharedCacheImagePathsSet() -> Set<String> {
        if let dyldSharedCacheImagePathsSetCache {
            return dyldSharedCacheImagePathsSetCache
        }
        let set = Set(dyldSharedCacheImagePaths())
        dyldSharedCacheImagePathsSetCache = set
        return set
    }

    package static func invalidDyldSharedCacheImagePathsCache() {
        #log(.debug, "Invalidating dyld shared cache image paths cache")
        dyldSharedCacheImagePathsCache = nil
        dyldSharedCacheImagePathsSetCache = nil
    }

    package static var dyldSharedCacheImageRootNode: RuntimeImageNode {
        #log(.debug, "Building dyld shared cache image root node")
        let paths = dyldSharedCacheImagePaths()
        let node = RuntimeImageNode.rootNode(for: paths, name: "Dyld Shared Cache")
        #log(.debug, "Built dyld shared cache root node with \(paths.count, privacy: .public) images")
        return node
    }

    package static var otherImageRootNode: RuntimeImageNode {
        #log(.debug, "Building other image root node")
        let dyldSharedCacheImagePaths = dyldSharedCacheImagePaths()
        let allImagePaths = imageNames()
        let otherImagePaths = allImagePaths.filter { !dyldSharedCacheImagePaths.contains($0) }
        let node = RuntimeImageNode.rootNode(for: otherImagePaths, name: "Others")
        #log(.debug, "Built other images root node with \(otherImagePaths.count, privacy: .public) images")
        return node
    }
}
