import Foundation
import FoundationToolbox
import MachOKit

extension RuntimeEngine {
    public func isImageIndexed(path: String) async throws -> Bool {
        try await request {
            let normalized = DyldUtilities.patchImagePathForDyld(path)
            let hasObjC = await objcSectionFactory.hasCachedSection(for: normalized)
            let hasSwift = await swiftSectionFactory.hasCachedSection(for: normalized)
            return hasObjC && hasSwift
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .isImageIndexed, request: path)
        }
    }

    /// Path of the target process's main executable (dyld image at index 0).
    public func mainExecutablePath() async throws -> String {
        try await request {
            // dyld guarantees image index 0 is the main executable.
            DyldUtilities.imageNames().first ?? ""
        } remote: { senderConnection in
            try await senderConnection.sendMessage(name: .mainExecutablePath)
        }
    }

    /// Like `loadImage(at:)` but does **not** call `reloadData()`.
    /// Used by the background indexing manager to avoid UI refresh storms.
    public func loadImageForBackgroundIndexing(at path: String) async throws {
        try await request {
            // Mirror loadImage(at:) byte-for-byte sans reloadData. See loadImage
            // for the canonicalization rationale.
            let canonical = DyldUtilities.patchImagePathForDyld(path)
            try DyldUtilities.loadImage(at: canonical)
            _ = try await objcSectionFactory.section(for: canonical)
            _ = try await swiftSectionFactory.section(for: canonical)
            loadedImagePaths.insert(canonical)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(
                name: .loadImageForBackgroundIndexing, request: path)
        }
    }
}

// MARK: - BackgroundIndexingEngineRepresenting

extension RuntimeEngine: BackgroundIndexingEngineRepresenting {
    /// `MachOImage(name:)` matches the basename of a loaded image (without the
    /// dylib / framework extension). Mirrors the conversion done in
    /// `RuntimeObjCSection` / `RuntimeSwiftSection` so the protocol callers can
    /// pass a full filesystem path.
    ///
    /// Examples:
    /// - `Foundation.framework/Foundation` → `Foundation` (single extension)
    /// - `libobjc.A.dylib` → `libobjc.A` → `libobjc` (versioned dylib needs both strips)
    ///
    /// TODO: Consolidate with the identical conversion in `RuntimeObjCSection`
    /// and `RuntimeSwiftSection` once we have a stable home in `DyldUtilities`.
    private static func machOImageName(forPath path: String) -> String {
        path.lastPathComponent.deletingPathExtension.deletingPathExtension
    }

    func canOpenImage(at path: String) -> Bool {
        MachOImage(name: Self.machOImageName(forPath: path)) != nil
    }

    func rpaths(for path: String) -> [String] {
        guard let image = MachOImage(name: Self.machOImageName(forPath: path)) else {
            return []
        }
        return image.rpaths
    }

    func dependencies(for path: String) async throws
        -> [(installName: String, resolvedPath: String?)]
    {
        guard let image = MachOImage(name: Self.machOImageName(forPath: path)) else {
            return []
        }
        let resolver = DylibPathResolver()
        let main = try await mainExecutablePath()
        let rpathList = image.rpaths
        return image.dependencies
            .filter { $0.type != .lazyLoad }
            .map { dependency in
                let installName = dependency.dylib.name
                let resolvedPath = resolver.resolve(
                    installName: installName,
                    imagePath: path,
                    rpaths: rpathList,
                    mainExecutablePath: main
                )
                return (installName, resolvedPath)
            }
    }
}
