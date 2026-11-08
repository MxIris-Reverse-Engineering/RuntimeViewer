#if os(macOS) && arch(arm64)

import Foundation
import Testing
import MachOKit
@testable import RuntimeViewerCore

/// `RuntimeSharedCachePartition`: which engine keeps each image of this Mac's
/// shared cache, decided by the kind of process that can load the image.
@Suite("Shared cache partition")
struct RuntimeSharedCachePartitionTests {
    private static let partition = RuntimeSharedCachePartition.current()

    private static func requirePartition() throws -> RuntimeSharedCachePartition {
        try #require(partition, "a process on Apple Silicon maps the arm64e shared cache")
    }

    private static func isInCache(_ imagePath: String) -> Bool {
        partition?.imagePaths.contains(imagePath) ?? false
    }

    @Test(
        "Images a macOS process can load belong to macOS",
        arguments: [
            // Zippered with Mac Catalyst.
            "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
            "/System/Library/Frameworks/Foundation.framework/Versions/C/Foundation",
            // Built for macOS alone.
            "/usr/lib/libobjc.A.dylib",
            "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI",
        ]
    )
    func macOSImages(imagePath: String) throws {
        let partition = try Self.requirePartition()
        #expect(partition.platform(ofImageAt: imagePath) == .macOS)
    }

    @Test(
        "Images built for Mac Catalyst alone belong to Mac Catalyst",
        arguments: [
            "/System/iOSSupport/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore",
            // The Mac Catalyst twin of the macOS SwiftUI above.
            "/System/iOSSupport/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI",
        ]
    )
    func macCatalystImages(imagePath: String) throws {
        let partition = try Self.requirePartition()
        #expect(partition.platform(ofImageAt: imagePath) == .macCatalyst)
    }

    /// The two kinds of image that make a path prefix the wrong rule, as
    /// macOS 27.2 has them.
    @Test(
        "A Mac Catalyst image outside iOSSupport belongs to Mac Catalyst",
        .enabled(if: isInCache("/System/Library/PrivateFrameworks/MaterialKit.framework/Versions/A/MaterialKit"))
    )
    func macCatalystImageOutsideIOSSupport() throws {
        let partition = try Self.requirePartition()
        #expect(partition.platform(ofImageAt: "/System/Library/PrivateFrameworks/MaterialKit.framework/Versions/A/MaterialKit") == .macCatalyst)
    }

    @Test(
        "A macOS image inside iOSSupport belongs to macOS",
        .enabled(if: isInCache("/System/iOSSupport/System/Library/PrivateFrameworks/AuthKitUIMacHelper.framework/Versions/A/AuthKitUIMacHelper"))
    )
    func macOSImageInsideIOSSupport() throws {
        let partition = try Self.requirePartition()
        #expect(partition.platform(ofImageAt: "/System/iOSSupport/System/Library/PrivateFrameworks/AuthKitUIMacHelper.framework/Versions/A/AuthKitUIMacHelper") == .macOS)
    }

    @Test("A path the cache does not list has no platform")
    func pathOutsideTheCache() throws {
        let partition = try Self.requirePartition()
        #expect(partition.platform(ofImageAt: "/usr/local/lib/libNotInTheSharedCache.dylib") == nil)
    }

    @Test("The image tree lists every image of the cache, under the shared root name")
    func imageTreeListsEveryImage() throws {
        let partition = try Self.requirePartition()
        #expect(partition.imageRootNode.name == "Dyld Shared Cache")
        var leafPaths: Set<String> = []
        func collectLeaves(of node: RuntimeImageNode) {
            if node.isLeaf {
                leafPaths.insert(node.path)
            }
            node.children.forEach(collectLeaves(of:))
        }
        collectLeaves(of: partition.imageRootNode)
        #expect(leafPaths == partition.imagePaths)
    }

    @Test(
        "An image belongs to Mac Catalyst only when its build versions name Mac Catalyst and not macOS",
        arguments: [
            ([Platform.macOS], RuntimeSharedCacheImagePlatform.macOS),
            ([Platform.macOS, Platform.macCatalyst], RuntimeSharedCacheImagePlatform.macOS),
            ([Platform.macCatalyst, Platform.macOS], RuntimeSharedCacheImagePlatform.macOS),
            ([Platform.macCatalyst], RuntimeSharedCacheImagePlatform.macCatalyst),
            ([], RuntimeSharedCacheImagePlatform.macOS),
        ]
    )
    func platformOfBuildVersions(platforms: [Platform], expectedPlatform: RuntimeSharedCacheImagePlatform) {
        #expect(RuntimeSharedCachePartition.platform(ofImageBuiltFor: platforms) == expectedPlatform)
    }
}

#endif
