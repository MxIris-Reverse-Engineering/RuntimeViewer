import Foundation
import RuntimeViewerCore

/// What a node of the image tree, or the image at a path, is — the one place every list of images
/// decides which icon a row shows (proposal `image-kind-icons`). A row names it as
/// `IconDescriptor.imageKind(_:)` and `ColorDescriptor.imageKind(_:)`; RuntimeViewerAppUI picks the
/// symbol and the colour (`RuntimeImageKind.icon`, `iconColor`, `coloredIcon` there).
///
/// A directory is the bundle its extension names, compared without regard to case as the system does;
/// a directory of any other extension, or of none, is a folder. A file is a dynamic library by the
/// `.dylib` extension and an image otherwise, whatever directory it is in.
public enum RuntimeImageKind: Hashable, Sendable, CaseIterable {
    /// A directory that is none of the bundles below.
    case folder

    /// A `.framework`.
    case framework

    /// Any other bundle: a `.bundle`, a `.plugin`, or one of the other extensions in
    /// `bundleExtensions`.
    case bundle

    /// An `.app`.
    case application

    /// An `.appex`, an app extension.
    case applicationExtension

    /// An `.xpc`, an XPC service.
    case xpcService

    /// A `.systemextension`.
    case systemExtension

    /// A `.kext`.
    case kernelExtension

    /// A `.prefPane`.
    case preferencePane

    /// A `.saver`, a screen saver.
    case screenSaver

    /// A `.dylib` file. For an image path, one in none of the bundles above.
    case dynamicLibrary

    /// Any other Mach-O file — the executable inside an app or a bundle, the binary of a framework, a
    /// tool — whether its name has an extension or not. For an image path, one in none of the bundles
    /// above.
    case image

    /// What the Mach-O file at `imagePath` is by its own name, whatever it is part of: a dynamic
    /// library by the `.dylib` extension, otherwise an image. What a tree of paths shows for an image,
    /// where its bundle is a node of its own.
    public init(imageFileAt imagePath: String) {
        self = (imagePath as NSString).pathExtension.lowercased() == "dylib" ? .dynamicLibrary : .image
    }

    /// The bundle kind a directory named with `pathExtension` is, or `nil` for any other directory.
    private init?(bundleExtension pathExtension: String) {
        switch pathExtension.lowercased() {
        case "framework":
            self = .framework
        case "app":
            self = .application
        case "appex":
            self = .applicationExtension
        case "xpc":
            self = .xpcService
        case "systemextension":
            self = .systemExtension
        case "kext":
            self = .kernelExtension
        case "prefpane":
            self = .preferencePane
        case "saver":
            self = .screenSaver
        case let otherExtension where Self.bundleExtensions.contains(otherExtension):
            self = .bundle
        default:
            return nil
        }
    }

    /// The extensions of the bundles that are none of the kinds above, in lower case: every one on
    /// the path of an image in the shared caches of macOS 27.2, iOS 27.0 and its simulator, and of
    /// the Mach-O files on a Mac with Xcode and the simulator runtimes installed (2026-11-14), less
    /// the directories that only look like bundles — a version number, a reverse-DNS name, an SDK or
    /// a toolchain, which hold no bundle's layout. A directory of an extension missing here is a
    /// folder.
    private static let bundleExtensions: Set<String> = [
        "action", "addresshandler", "assistantbundle", "axbundle", "axuiservice", "brailledriver",
        "brailletable", "bundle", "caction", "cifilter", "component", "coredeviceplugin", "csutil",
        "daplug", "dataconsumer", "desplugin", "devicechrome", "devicekitplugin", "dext", "docktileplugin",
        "driver", "dsclext", "dsym", "dvtplugin", "feature", "flowtool", "flplugin", "fs", "fxp", "fxplug",
        "gdtdplugin", "gtplugin", "gtpplugin_ios", "gtpplugin_osx", "gtpplugin_tvos", "gtpplugin_watchos",
        "gtpplugin_xros", "healthplugin", "icdplugin", "ideplugin", "ilmbplugin", "imservice", "jdk",
        "lockbundle", "loginplugin", "mdimporter", "mediastream", "menu", "migrator", "monitorpanel",
        "monitorpanels", "mrplugin", "oesystemplugin", "opplugin", "osax", "ozp", "platform", "plugin",
        "pluginkit", "ppp", "profiledomainplugin", "proofingtool", "prrplugin", "qldisplay", "qlgenerator",
        "radplug", "rcplugin", "scripting", "seplugin", "service", "settings", "simdeviceio",
        "simdevicetype", "simdeviceui", "simruntime", "siriuibundle", "siriuipresentationbundle", "slotd",
        "sourcebundle", "speechbundle", "speechsynthesizer", "spreporter", "syncbundle", "syncschema",
        "transport", "vfxlibrary", "vpn", "vsplugin", "vzplugin", "wkbundle", "xcpext", "xlplugin",
        "xrcliplugin", "xrplugin", "xruiplugin",
    ]

    /// What `node` is, by its own name: a leaf is a file, a dynamic library or an image
    /// (`init(imageFileAt:)`); any other node is a directory, the bundle its extension names or a
    /// folder. `AppKit.framework` is a framework; the `AppKit` inside it, an image; `libobjc.A.dylib`, a
    /// dynamic library.
    public init(node: RuntimeImageNode) {
        if node.isLeaf {
            self = Self(imageFileAt: node.name)
        } else {
            self = Self(bundleExtension: (node.name as NSString).pathExtension) ?? .folder
        }
    }

    /// What the image at `imagePath` is part of: the bundle on its path nearest to it, or, when it is
    /// in none, what the file itself is. AppKit's is a framework, `/usr/lib/libobjc.A.dylib` a dynamic
    /// library.
    public init(ofImageAt imagePath: String) {
        let directoryNames = (imagePath as NSString).pathComponents.dropLast()
        let nearestBundleKind = directoryNames.reversed().lazy
            .compactMap { Self(bundleExtension: ($0 as NSString).pathExtension) }
            .first
        self = nearestBundleKind ?? Self(imageFileAt: imagePath)
    }
}

extension RuntimeImageNode {
    /// What this node is (`RuntimeImageKind(node:)`).
    public var kind: RuntimeImageKind {
        RuntimeImageKind(node: self)
    }
}
