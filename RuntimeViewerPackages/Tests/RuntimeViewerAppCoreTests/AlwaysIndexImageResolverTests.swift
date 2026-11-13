import Foundation
import RuntimeViewerCommunication
import Testing
@testable import RuntimeViewerAppCore
@testable import RuntimeViewerCore

/// What an Always Index row names on one engine. Without owners only what the engine's process
/// loaded; with them any shared cache image an owner keeps — the owner loads it — and, for a name
/// both platforms have, the image built for the platform of the engine's process.
@Suite("Always Index image resolution")
struct AlwaysIndexImageResolverTests {
    private static let appKit = "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit"
    private static let macOSSwiftUI = "/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI"
    private static let macCatalystSwiftUI = "/System/iOSSupport/System/Library/Frameworks/SwiftUI.framework/Versions/A/SwiftUI"
    private static let uikitCore = "/System/iOSSupport/System/Library/PrivateFrameworks/UIKitCore.framework/Versions/A/UIKitCore"
    private static let attachedExecutable = "/Applications/Notes.app/Contents/MacOS/Notes"

    private static let partition = RuntimeSharedCachePartition(
        cacheUUID: UUID(),
        orderedImagePaths: [appKit, macOSSwiftUI, macCatalystSwiftUI, uikitCore],
        macCatalystOnlyImagePaths: [macCatalystSwiftUI, uikitCore]
    )

    private static let macOSOwner = RuntimeEngine(source: .local, engineID: "AlwaysIndexImageResolverTests.macOS")
    private static let macCatalystOwner = RuntimeEngine(source: macCatalystSource, engineID: "AlwaysIndexImageResolverTests.macCatalyst")
    private static let macCatalystSource = RuntimeSource.remote(name: "My Mac (Mac Catalyst)", identifier: .macCatalyst, role: .client)
    private static let attachedSource = RuntimeSource.remote(name: "Notes", identifier: "701", role: .client)

    private static let bothOwners = RuntimeSharedCacheOwners(partition: partition, macOS: macOSOwner, macCatalyst: macCatalystOwner)

    @Test("without owners a row names only an image the engine's process loaded")
    func withoutOwnersOnlyLoadedImages() {
        let resolver = AlwaysIndexImageResolver(loadedImagePaths: [Self.appKit], sharedCacheOwners: nil, source: Self.attachedSource)

        #expect(resolver.imagePath(for: "AppKit") == Self.appKit)
        #expect(resolver.imagePath(for: Self.appKit) == Self.appKit)
        #expect(resolver.imagePath(for: "SwiftUI") == nil)
        #expect(resolver.imagePath(for: Self.macOSSwiftUI) == nil)
    }

    @Test("with owners a row names a shared cache image nothing loaded, by name or by path")
    func withOwnersAnySharedCacheImage() {
        let resolver = AlwaysIndexImageResolver(loadedImagePaths: [Self.attachedExecutable], sharedCacheOwners: Self.bothOwners, source: Self.attachedSource)

        #expect(resolver.imagePath(for: "AppKit") == Self.appKit)
        #expect(resolver.imagePath(for: Self.appKit) == Self.appKit)
        #expect(resolver.imagePath(for: "Notes") == Self.attachedExecutable)
        #expect(resolver.imagePath(for: "Pages") == nil)
    }

    @Test(
        "a name both platforms have names the image built for the platform of the engine's process",
        arguments: [
            (source: RuntimeSource.local, loadedImagePaths: [String](), expected: macOSSwiftUI),
            (source: attachedSource, loadedImagePaths: [attachedExecutable], expected: macOSSwiftUI),
            (source: macCatalystSource, loadedImagePaths: [], expected: macCatalystSwiftUI),
            (source: attachedSource, loadedImagePaths: [attachedExecutable, uikitCore], expected: macCatalystSwiftUI),
        ]
    )
    func sharedNamePrefersTheProcessPlatform(source: RuntimeSource, loadedImagePaths: [String], expected: String) {
        let resolver = AlwaysIndexImageResolver(loadedImagePaths: loadedImagePaths, sharedCacheOwners: Self.bothOwners, source: source)

        #expect(resolver.imagePath(for: "SwiftUI") == expected)
    }

    @Test("an image built for Mac Catalyst alone is named only while the Mac Catalyst engine is up")
    func macCatalystImageNeedsTheMacCatalystOwner() {
        let ownersWithoutMacCatalyst = RuntimeSharedCacheOwners(partition: Self.partition, macOS: Self.macOSOwner, macCatalyst: nil)
        let withoutMacCatalyst = AlwaysIndexImageResolver(loadedImagePaths: [], sharedCacheOwners: ownersWithoutMacCatalyst, source: .local)
        let withMacCatalyst = AlwaysIndexImageResolver(loadedImagePaths: [], sharedCacheOwners: Self.bothOwners, source: .local)

        #expect(withoutMacCatalyst.imagePath(for: "UIKitCore") == nil)
        #expect(withoutMacCatalyst.imagePath(for: Self.uikitCore) == nil)
        #expect(withoutMacCatalyst.imagePath(for: "SwiftUI") == Self.macOSSwiftUI)
        #expect(withMacCatalyst.imagePath(for: "UIKitCore") == Self.uikitCore, "My Mac's row for UIKitCore is not handed to Mac Catalyst")
    }

    @Test("a blank row names nothing", arguments: ["", "   ", "\n"])
    func blankRowNamesNothing(identifier: String) {
        let resolver = AlwaysIndexImageResolver(loadedImagePaths: [Self.appKit], sharedCacheOwners: Self.bothOwners, source: .local)

        #expect(resolver.imagePath(for: identifier) == nil)
    }
}
