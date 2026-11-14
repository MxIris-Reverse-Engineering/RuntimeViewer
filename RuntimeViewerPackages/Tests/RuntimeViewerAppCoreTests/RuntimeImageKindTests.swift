import AppKit
import Testing
import RuntimeViewerCore
@testable import RuntimeViewerAppCore
import RuntimeViewerAppTestingSupport

/// The one place every list of images decides what an image is (proposal `image-kind-icons`):
/// a node of the image tree by its own name, the image at a path by the bundle nearest to it, and the
/// colour its icon is drawn in, Xcode's for that kind of file.
@Suite("Image kinds")
struct RuntimeImageKindTests {
    private static let imagePaths = [
        "/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit",
        "/usr/lib/libobjc.A.dylib",
        "/Applications/Safari.app/Contents/MacOS/Safari",
        "/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily",
        "/System/Library/Extensions/AGXMetalG13X.bundle/Contents/MacOS/AGXMetalG13X",
        "/System/Library/Frameworks/QuickLookUI.framework/PlugIns/Preview.plugin/Contents/MacOS/Preview",
        "/Applications/Mail.app/Contents/PlugIns/MailShareExtension.appex/Contents/MacOS/MailShareExtension",
        "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking",
        "/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Resources/UVCAssistant.systemextension/Contents/MacOS/UVCAssistant",
        "/System/Library/PreferencePanes/Appearance.prefPane/Contents/MacOS/Appearance",
        "/System/Library/Screen Savers/Random.saver/Contents/MacOS/Random",
        "/System/Library/QuickLook/Web.qlgenerator/Contents/MacOS/Web",
        // An iOS bundle keeps its executable at its top.
        "/System/Library/AccessibilityBundles/ARKit.axbundle/ARKit",
        "/System/Library/Accounts/Notification/com.apple.askpermission.AccountNotificationPlugin.bundle/Contents/MacOS/com.apple.askpermission.AccountNotificationPlugin",
        "/opt/homebrew/Cellar/imagemagick/7.1.2-35/bin/magick",
        "/opt/homebrew/lib/ruby/gems/4.0.0/extensions/arm64-darwin-20/fiddle.bundle",
    ]

    @Test(
        "a node of the image tree is what its own name says",
        arguments: [
            ("AppKit.framework", RuntimeImageKind.framework),
            // A framework's binary is a file like any other: only a `.dylib` is a dynamic library.
            ("AppKit", .image),
            ("Safari", .image),
            ("Preview", .image),
            ("Frameworks", .folder),
            ("usr", .folder),
            ("libobjc.A.dylib", .dynamicLibrary),
            ("Safari.app", .application),
            ("MailShareExtension.appex", .applicationExtension),
            ("com.apple.WebKit.Networking.xpc", .xpcService),
            ("UVCAssistant.systemextension", .systemExtension),
            ("IOUSBHostFamily.kext", .kernelExtension),
            ("Appearance.prefPane", .preferencePane),
            ("Random.saver", .screenSaver),
            ("AGXMetalG13X.bundle", .bundle),
            ("Preview.plugin", .bundle),
            ("Web.qlgenerator", .bundle),
            ("ARKit.axbundle", .bundle),
            ("ARKit", .image),
            // A name with dots in it, whose last part is no extension of a Mach-O file.
            ("com.apple.askpermission.AccountNotificationPlugin", .image),
            // A version number is no bundle's extension.
            ("7.1.2-35", .folder),
            ("magick", .image),
            // A file named like a bundle is still a file.
            ("fiddle.bundle", .image),
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
            ("/usr/lib/libobjc.A.dylib", .dynamicLibrary),
            ("/usr/lib/swift/libswiftCore.dylib", .dynamicLibrary),
            ("/usr/libexec/rapportd", .image),
            ("/Applications/Safari.app/Contents/MacOS/Safari", .application),
            ("/System/Library/Extensions/IOUSBHostFamily.kext/Contents/MacOS/IOUSBHostFamily", .kernelExtension),
            ("/System/Library/Extensions/AGXMetalG13X.bundle/Contents/MacOS/AGXMetalG13X", .bundle),
            ("/Applications/Mail.app/Contents/PlugIns/MailShareExtension.appex/Contents/MacOS/MailShareExtension", .applicationExtension),
            ("/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking", .xpcService),
            ("/System/Library/Frameworks/CoreMediaIO.framework/Versions/A/Resources/UVCAssistant.systemextension/Contents/MacOS/UVCAssistant", .systemExtension),
            ("/System/Library/PreferencePanes/Appearance.prefPane/Contents/MacOS/Appearance", .preferencePane),
            // The system compares extensions without regard to case.
            ("/Library/PreferencePanes/SwiftDefaultApps.prefpane/Contents/MacOS/SwiftDefaultApps", .preferencePane),
            ("/System/Library/Screen Savers/Random.saver/Contents/MacOS/Random", .screenSaver),
            ("/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/DVTFoundation", .framework),
            ("/Applications/Xcode.app/Contents/PlugIns/IDEDistribution.ideplugin/Contents/MacOS/IDEDistribution", .bundle),
            ("/System/Library/DriverExtensions/com.apple.DriverKit-AppleUSBFTDI.dext/com.apple.DriverKit-AppleUSBFTDI", .bundle),
            ("/System/Library/Frameworks/Tcl.framework/Versions/8.5/Tcl", .framework),
            // A directory of an extension that is not a bundle's: the nearest bundle further up.
            ("/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend", .application),
            ("/opt/homebrew/Cellar/imagemagick/7.1.2-35/bin/magick", .image),
        ]
    )
    func imageKind(imagePath: String, expectedKind: RuntimeImageKind) {
        #expect(RuntimeImageKind(ofImageAt: imagePath) == expectedKind)
    }

    @Test(
        "a file of a tree is a dynamic library by the .dylib extension and an image otherwise, whatever it is part of",
        arguments: [
            ("/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit", RuntimeImageKind.image),
            ("/usr/lib/libobjc.A.dylib", .dynamicLibrary),
            ("/Applications/Safari.app/Contents/Frameworks/libSafariShared.dylib", .dynamicLibrary),
            ("/usr/libexec/rapportd", .image),
            ("/Applications/Safari.app/Contents/MacOS/Safari", .image),
            ("/System/Library/MediaCapture/H13ISP.mediacapture", .image),
            ("/opt/homebrew/lib/python3.13/lib-dynload/_ssl.cpython-313-darwin.so", .image),
        ]
    )
    func imageFileKind(imagePath: String, expectedKind: RuntimeImageKind) {
        #expect(RuntimeImageKind(imageFileAt: imagePath) == expectedKind)
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

    /// Xcode's `doc-steel`, from the same catalog: Display P3 98, 127, 147 in the light appearance and
    /// sRGB 183, 213, 235 in the dark. Not a system colour.
    static let xcodeSteel = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(srgbRed: 183 / 255, green: 213 / 255, blue: 235 / 255, alpha: 1)
            : NSColor(displayP3Red: 98 / 255, green: 127 / 255, blue: 147 / 255, alpha: 1)
    }

    @Test(
        "a kind's colour is the one Xcode draws that kind of file in, in the light and the dark appearance",
        arguments: [
            (RuntimeImageKind.folder, RuntimeImageKindTests.xcodeLightBlue),
            (.bundle, RuntimeImageKindTests.xcodeLightBlue),
            (.applicationExtension, RuntimeImageKindTests.xcodeLightBlue),
            (.systemExtension, RuntimeImageKindTests.xcodeLightBlue),
            (.kernelExtension, RuntimeImageKindTests.xcodeLightBlue),
            (.preferencePane, RuntimeImageKindTests.xcodeLightBlue),
            (.screenSaver, RuntimeImageKindTests.xcodeLightBlue),
            // DVTUserInterfaceKit's `doc-yellow` names the system colour.
            (.framework, NSColor.systemYellow),
            // Xcode gives an app's icon no colour and draws it in this one.
            (.application, .secondaryLabelColor),
            (.xpcService, RuntimeImageKindTests.xcodeSteel),
            (.dynamicLibrary, RuntimeImageKindTests.xcodeSteel),
            // Xcode's for a file it has no other icon for (`public.item`).
            (.image, RuntimeImageKindTests.xcodeSteel),
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
