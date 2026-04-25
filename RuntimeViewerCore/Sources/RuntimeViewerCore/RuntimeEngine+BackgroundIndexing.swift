import Foundation
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
            // Mirror loadImage(at:) byte-for-byte sans reloadData(isReloadImageNodes:).
            try DyldUtilities.loadImage(at: path)
            _ = try await objcSectionFactory.section(for: path)
            _ = try await swiftSectionFactory.section(for: path)
            loadedImagePaths.insert(path)
        } remote: { senderConnection in
            try await senderConnection.sendMessage(
                name: .loadImageForBackgroundIndexing, request: path)
        }
    }
}
