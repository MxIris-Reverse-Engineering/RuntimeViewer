public import Foundation
import FoundationToolbox
import MachOKit

/// The images of the dyld shared cache this process maps, each with the kind
/// of process that can load it.
///
/// Read once from the cache's own headers, without loading any image: every
/// image of the cache is mapped into every process that uses the cache, so the
/// app process — which never loads or indexes an image itself — can build it
/// too. Every process on this Mac that runs natively on Apple Silicon maps the
/// same cache, `dyld_shared_cache_arm64e`: dyld picks the cache file by its own
/// architecture, and dyld is arm64e whether the process is arm64 or arm64e.
///
/// A class rather than a struct because the image tree it builds,
/// ``imageRootNode``, is shared by every engine on the cache, and sharing that
/// one tree is part of what it is for. It is immutable once made: the tree is
/// built, every node's path included, before the initializer returns.
@Loggable
public final class RuntimeSharedCachePartition: @unchecked Sendable {
    /// The name of the root of every engine's shared cache image tree.
    public static let imageRootNodeName = "Dyld Shared Cache"

    /// The cache's UUID, from its main header.
    public let cacheUUID: UUID

    /// Every image of the cache, by the path dyld lists it under.
    public let imagePaths: Set<String>

    /// The images built for Mac Catalyst only.
    private let macCatalystOnlyImagePaths: Set<String>

    /// The cache's images as one tree, in the order the cache lists them — the
    /// tree every engine on this cache shows under ``imageRootNodeName``.
    public let imageRootNode: RuntimeImageNode

    /// `orderedImagePaths` in the order the cache lists them, which is the
    /// order the image tree keeps; `macCatalystOnlyImagePaths` among them.
    init(cacheUUID: UUID, orderedImagePaths: [String], macCatalystOnlyImagePaths: Set<String>) {
        self.cacheUUID = cacheUUID
        self.imagePaths = Set(orderedImagePaths)
        self.macCatalystOnlyImagePaths = macCatalystOnlyImagePaths.intersection(imagePaths)
        let imageRootNode = RuntimeImageNode.rootNode(for: orderedImagePaths, name: Self.imageRootNodeName)
        // Every node's path is lazy; working them all out here leaves the
        // tree nothing to write when engines on several threads read it.
        Self.resolvePaths(of: imageRootNode)
        self.imageRootNode = imageRootNode
    }

    /// The partition of the cache this process maps; `nil` when it maps none.
    public static func current() -> RuntimeSharedCachePartition? {
        guard let cache = DyldCacheLoaded.current,
              let slide = cache.slide,
              let imageInfos = cache.imageInfos
        else {
            #log(.default, "This process maps no dyld shared cache to partition")
            return nil
        }
        var orderedImagePaths: [String] = []
        var macCatalystOnlyImagePaths: Set<String> = []
        for imageInfo in imageInfos {
            guard let imagePath = imageInfo.path(in: cache) else { continue }
            orderedImagePaths.append(imagePath)
            guard let headerPointer = UnsafeRawPointer(bitPattern: Int(imageInfo.address) + slide) else { continue }
            let image = MachOImage(ptr: headerPointer.assumingMemoryBound(to: mach_header.self))
            let platforms = image.loadCommands.infos(of: LoadCommand.buildVersion).map(\.platform)
            if platform(ofImageBuiltFor: platforms) == .macCatalyst {
                macCatalystOnlyImagePaths.insert(imagePath)
            }
        }
        let partition = RuntimeSharedCachePartition(
            cacheUUID: cache.mainCacheHeader.uuid,
            orderedImagePaths: orderedImagePaths,
            macCatalystOnlyImagePaths: macCatalystOnlyImagePaths
        )
        #log(.info, "Partitioned the shared cache \(partition.cacheUUID.uuidString, privacy: .public): \(partition.imagePaths.count, privacy: .public) images, \(partition.macCatalystOnlyImagePaths.count, privacy: .public) of them for Mac Catalyst only")
        return partition
    }

    /// The kind of process that can load the image at `imagePath`, or `nil`
    /// when the cache has no image at that path.
    public func platform(ofImageAt imagePath: String) -> RuntimeSharedCacheImagePlatform? {
        guard imagePaths.contains(imagePath) else { return nil }
        return macCatalystOnlyImagePaths.contains(imagePath) ? .macCatalyst : .macOS
    }

    /// The kind of process that loads an image whose `LC_BUILD_VERSION`
    /// commands name `platforms`: Mac Catalyst only when they name Mac
    /// Catalyst and not macOS. An image with no build version at all predates
    /// the command, and so predates Mac Catalyst.
    static func platform(ofImageBuiltFor platforms: some Sequence<Platform>) -> RuntimeSharedCacheImagePlatform {
        var namesMacCatalyst = false
        for platform in platforms {
            switch platform {
            case .macOS:
                return .macOS
            case .macCatalyst:
                namesMacCatalyst = true
            default:
                break
            }
        }
        return namesMacCatalyst ? .macCatalyst : .macOS
    }

    private static func resolvePaths(of node: RuntimeImageNode) {
        _ = node.absolutePath
        for child in node.children {
            resolvePaths(of: child)
        }
    }
}
