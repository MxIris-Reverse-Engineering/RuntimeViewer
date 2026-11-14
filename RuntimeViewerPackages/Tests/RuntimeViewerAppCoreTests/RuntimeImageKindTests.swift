import AppKit
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The one place every list of images decides what an image is (proposal `draft-image-kind-icons`):
/// a node of the image tree by its own name, the image at a path by the bundle nearest to it — and
/// the colour its icon is drawn in, Xcode's for that kind of file.
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

    // MARK: - Colours

    /// Xcode's `doc-lightBlue` as DVTUserInterfaceKit's asset catalog lists it (Xcode 27.2): sRGB
    /// 70, 169, 255 in the light appearance and 66, 173, 255 in the dark. Not a system colour.
    static let xcodeLightBlue = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 66 / 255, green: 173 / 255, blue: 255 / 255, alpha: 1)
            : NSColor(srgbRed: 70 / 255, green: 169 / 255, blue: 255 / 255, alpha: 1)
    }

    @Test(
        "a kind's colour is the one Xcode draws that kind of file in, in the light and the dark appearance",
        arguments: [
            (RuntimeImageKind.folder, RuntimeImageKindTests.xcodeLightBlue),
            (.bundle, RuntimeImageKindTests.xcodeLightBlue),
            (.kernelExtension, RuntimeImageKindTests.xcodeLightBlue),
            // DVTUserInterfaceKit's `doc-yellow` names the system colour.
            (.framework, NSColor.systemYellow),
            // Xcode gives an app's icon no colour and draws it in this one.
            (.application, .secondaryLabelColor),
            // Not Xcode's: an image file keeps the accent colour.
            (.image, .controlAccentColor),
        ]
    )
    func iconColor(kind: RuntimeImageKind, expectedColor: NSColor) {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(ImageColorSampling.isSameColor(kind.iconColor, expectedColor, in: appearance), "in \(appearance.rawValue)")
        }
    }

    @Test("a kind's coloured icon is drawn as it is, in the kind's colour", arguments: RuntimeImageKind.allCases)
    func coloredIcon(kind: RuntimeImageKind) {
        #expect(!kind.coloredIcon.isTemplate, "a template image would be drawn in the colour of the view or the menu")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            #expect(ImageColorSampling.isDrawn(kind.coloredIcon, in: kind.iconColor, appearance: appearance), "in \(appearance.rawValue)")
        }
    }

    @Test("a row of the image tree shows its node's icon in the colour of the node's kind")
    func imageTreeRowColor() throws {
        let rootNode = RuntimeImageNode.rootNode(for: Self.imagePaths)
        let frameworkNode = try #require(rootNode.first { $0.name == "AppKit.framework" })
        let folderNode = try #require(rootNode.first { $0.name == "Frameworks" })

        let frameworkAppearance = SidebarRootCellViewModel(node: frameworkNode).appearance
        let folderAppearance = SidebarRootCellViewModel(node: folderNode).appearance

        #expect(frameworkAppearance.icon === RuntimeImageKind.framework.icon)
        #expect(frameworkAppearance.iconColor == RuntimeImageKind.framework.iconColor)
        #expect(folderAppearance.icon === RuntimeImageKind.folder.icon)
        #expect(folderAppearance.iconColor == RuntimeImageKind.folder.iconColor)
    }
}
