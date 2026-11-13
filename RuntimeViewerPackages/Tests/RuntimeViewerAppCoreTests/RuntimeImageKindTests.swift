import AppKit
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore

/// The one place every list of images decides what an image is (proposal `draft-image-kind-icons`):
/// a node of the image tree by its own name, the image at a path by the bundle nearest to it.
@Suite("Image kinds")
struct RuntimeImageKindTests {
    private static let imagePaths = [
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/usr/lib/libobjc.A.dylib",
        "/Applications/Safari.app/Contents/MacOS/Safari",
        "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily",
        "/System/Library/Extensions/AGXMetalG13X.bundle/Contents/MacOS/AGXMetalG13X",
        "/System/Library/Frameworks/QuickLookUI.framework/PlugIns/Preview.plugin/Contents/MacOS/Preview",
    ]

    @Test(
        "a node of the image tree is what its own name says",
        arguments: [
            ("AppKit.framework", RuntimeImageKind.framework),
            ("AppKit", .image),
            ("Frameworks", .folder),
            ("usr", .folder),
            ("libobjc.A.dylib", .image),
            ("Safari.app", .application),
            ("IOUSBHostFamily.kext", .kernelExtension),
            ("AGXMetalG13X.bundle", .bundle),
            ("Preview.plugin", .bundle),
        ]
    )
    func nodeKind(name: String, expectedKind: RuntimeImageKind) throws {
        let rootNode = RuntimeImageNode.rootNode(for: Self.imagePaths)
        let node = try #require(rootNode.first { $0.name == name }, "no node named \(name)")

        #expect(node.kind == expectedKind)
    }

    @Test(
        "an image is what the bundle nearest to it on its path is, or an image in none",
        arguments: [
            ("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", RuntimeImageKind.framework),
            ("/System/Library/Frameworks/Foundation.framework/Foundation", .framework),
            ("/usr/lib/libobjc.A.dylib", .image),
            ("/usr/lib/swift/libswiftCore.dylib", .image),
            ("/Applications/Safari.app/Contents/MacOS/Safari", .application),
            ("/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily", .kernelExtension),
            ("/System/Library/Extensions/AGXMetalG13X.bundle/Contents/MacOS/AGXMetalG13X", .bundle),
            ("/Applications/Mail.app/Contents/PlugIns/MailShareExtension.appex/Contents/MacOS/MailShareExtension", .bundle),
            ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking", .bundle),
            ("/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/DVTFoundation", .framework),
            // A directory of an extension that is not a bundle's: the nearest bundle further up.
            ("/Applications/Xcode.app/Contents/PlugIns/IDEDistribution.ideplugin/Contents/MacOS/IDEDistribution", .application),
        ]
    )
    func imageKind(imagePath: String, expectedKind: RuntimeImageKind) {
        #expect(RuntimeImageKind(ofImageAt: imagePath) == expectedKind)
    }

    @Test("an image named like a bundle is still an image: only directories make the bundle")
    func fileNamedLikeABundle() {
        #expect(RuntimeImageKind(ofImageAt: "/tmp/Strange.framework") == .image)
    }

    @Test("every kind has a template icon, so a list draws it in its own colour", arguments: RuntimeImageKind.allCases)
    func iconIsTemplate(kind: RuntimeImageKind) {
        #expect(kind.icon.isTemplate)
    }
}
