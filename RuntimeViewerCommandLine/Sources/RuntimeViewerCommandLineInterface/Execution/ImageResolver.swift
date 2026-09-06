import Foundation
import RuntimeViewerCore

/// Turns the `--image` argument into loaded image paths.
///
/// Resolution order for a short name follows `MCPBridgeServer.resolveImagePaths`
/// and adds the engine's image catalog at the end, so a framework that is not
/// mapped into the host (`--image AppKit` on a fresh host) still resolves:
///
/// 1. loaded images, exact name without extension, then substring
/// 2. images mapped into the host, exact then substring
/// 3. the engine's catalog (shared cache and framework directories), exact then substring
/// 4. the name as a literal path
struct ImageResolver {
    let engine: RuntimeEngine

    /// The paths a command should search, each loaded into the engine.
    func resolveImagePaths(_ image: String?) async throws -> [String] {
        guard let image, !image.isEmpty else {
            let loaded = await engine.loadedImagePaths
            guard !loaded.isEmpty else {
                throw CommandFailure(
                    code: .imageNotFound,
                    message: "No image is loaded. Pass --image <path or name>, or run `load <path>` first."
                )
            }
            return loaded.sorted()
        }
        if image.hasPrefix("/") {
            try await ensureLoaded(image)
            return [image]
        }
        if let path = try await resolveShortName(image) {
            try await ensureLoaded(path)
            return [path]
        }
        throw CommandFailure(
            code: .imageNotFound,
            message: "No image matches '\(image)'. Pass an absolute path, or a short name of a loaded or system image (see `images`)."
        )
    }

    /// Resolves a short name to a path without loading it.
    func resolveShortName(_ name: String) async throws -> String? {
        let loaded = await engine.loadedImagePaths.sorted()
        if let match = Self.match(name, in: loaded) { return match }
        let mapped = await engine.imageList
        if let match = Self.match(name, in: mapped) { return match }
        let catalog = catalogPaths()
        if let match = Self.match(name, in: catalog) { return match }
        if FileManager.default.fileExists(atPath: name) {
            return URL(fileURLWithPath: name).standardizedFileURL.path
        }
        return nil
    }

    /// Loads an image into the engine if the host has not mapped it yet.
    func ensureLoaded(_ path: String) async throws {
        let isLoaded: Bool
        do {
            isLoaded = try await engine.isImageLoaded(path: path)
        } catch {
            throw CommandFailure(code: .imageLoadFailed, message: "Could not check whether '\(path)' is loaded: \(error.localizedDescription)")
        }
        guard !isLoaded else { return }
        do {
            try await engine.loadImage(at: path)
        } catch {
            throw CommandFailure(code: .imageLoadFailed, message: "Could not load '\(path)': \(error.localizedDescription)")
        }
    }

    /// Every leaf of the engine's image catalog as an absolute path.
    func catalogPaths() -> [String] {
        var paths: [String] = []
        for root in engine.imageNodes {
            Self.collectLeafPaths(of: root, into: &paths)
        }
        return paths
    }

    /// Exact match on the last path component without extension, then substring.
    static func match(_ name: String, in paths: [String]) -> String? {
        let needle = name.lowercased()
        if let exact = paths.first(where: { Self.baseName(of: $0).lowercased() == needle }) {
            return exact
        }
        return paths.first { ($0 as NSString).lastPathComponent.lowercased().contains(needle) }
    }

    static func baseName(of path: String) -> String {
        (((path as NSString).lastPathComponent) as NSString).deletingPathExtension
    }

    private static func collectLeafPaths(of node: RuntimeImageNode, into paths: inout [String]) {
        if node.isLeaf {
            paths.append(node.path)
            return
        }
        for child in node.children {
            collectLeafPaths(of: child, into: &paths)
        }
    }
}

extension RuntimeObject {
    /// Depth-first lookup by exact `name`, then exact `displayName`, then a
    /// case-insensitive match on either, descending into specializations.
    static func find(named name: String, in objects: [RuntimeObject]) -> RuntimeObject? {
        if let exact = firstMatch(in: objects, where: { $0.name == name || $0.displayName == name }) {
            return exact
        }
        let lowercased = name.lowercased()
        return firstMatch(in: objects, where: { $0.name.lowercased() == lowercased || $0.displayName.lowercased() == lowercased })
    }

    private static func firstMatch(in objects: [RuntimeObject], where predicate: (RuntimeObject) -> Bool) -> RuntimeObject? {
        for object in objects {
            if predicate(object) { return object }
            if let found = firstMatch(in: object.children, where: predicate) { return found }
        }
        return nil
    }
}

extension TypeInfo {
    init(_ object: RuntimeObject) {
        self.init(
            name: object.name,
            displayName: object.displayName,
            kind: object.kind.description,
            imagePath: object.imagePath,
            imageName: object.imageName
        )
    }
}
