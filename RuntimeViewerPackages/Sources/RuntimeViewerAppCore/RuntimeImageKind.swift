import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RuntimeViewerCore

/// What a node of the image tree, or the image at a path, is — the one place every list of images
/// decides which icon a row shows (proposal `image-kind-icons`).
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

    /// The kind's symbol at the system's default size, a template image, the one Xcode draws that kind
    /// of file with (the `Xcode.SymbolicIcon` extensions of DVTUserInterfaceKit, Xcode 27.2): its own
    /// for a framework, a bundle, an app, a system extension and a kernel extension; and the system's
    /// `folder.fill` for a folder, `e.circle.fill` for an app extension, `wrench.and.screwdriver.fill`
    /// for an XPC service, `switch.2` for a preference pane, `sparkles` for a screen saver,
    /// `building.columns.fill` for a dynamic library, and `doc` — Xcode's for any file it has no other
    /// icon for (`public.item`) — for any other image. A view that can tint a template draws it in
    /// `iconColor`, which a selected row turns white as Xcode's does; a view that draws an image as it
    /// is takes `coloredIcon`.
    public var icon: NSUIImage {
        switch self {
        case .folder: Self.folderIcon
        case .framework: Self.frameworkIcon
        case .bundle: Self.bundleIcon
        case .application: Self.applicationIcon
        case .applicationExtension: Self.applicationExtensionIcon
        case .xpcService: Self.xpcServiceIcon
        case .systemExtension: Self.systemExtensionIcon
        case .kernelExtension: Self.kernelExtensionIcon
        case .preferencePane: Self.preferencePaneIcon
        case .screenSaver: Self.screenSaverIcon
        case .dynamicLibrary: Self.dynamicLibraryIcon
        case .image: Self.imageIcon
        }
    }

    /// The colour Xcode draws this kind's icon in, from the same extensions: Xcode's own light blue
    /// for a folder (`public.folder`) and for the bundles but the three below, system yellow for a
    /// framework, Xcode's steel for an XPC service (the product type `com.apple.product-type.xpc-service`),
    /// a dynamic library (`com.apple.mach-o-dylib`) and any other image (`public.item`), and the
    /// secondary label colour for an app — Xcode gives an app's icon no colour of its own and draws it
    /// in that one.
    public var iconColor: NSUIColor {
        switch self {
        case .folder, .bundle, .applicationExtension, .systemExtension, .kernelExtension, .preferencePane, .screenSaver:
            Self.xcodeLightBlue
        case .framework:
            .systemYellow
        case .application:
            Self.secondaryLabelColor
        case .xpcService, .dynamicLibrary, .image:
            Self.xcodeSteel
        }
    }

    /// Xcode's `doc-lightBlue`: not a system colour, one value for the light appearance and one for
    /// the dark, both sRGB.
    private static let xcodeLightBlue = NSUIColor(
        light: NSUIColor.sRGB(red: 70, green: 169, blue: 255),
        dark: NSUIColor.sRGB(red: 66, green: 173, blue: 255)
    )

    /// Xcode's `doc-steel`: not a system colour; Display P3 in the light appearance, sRGB in the dark.
    private static let xcodeSteel = NSUIColor(
        light: NSUIColor.displayP3(red: 98, green: 127, blue: 147),
        dark: NSUIColor.sRGB(red: 183, green: 213, blue: 235)
    )

    #if os(macOS)
    private static let secondaryLabelColor = NSColor.secondaryLabelColor
    #else
    private static let secondaryLabelColor = UIColor.secondaryLabel
    #endif

    // Loaded once each: every row of every list asks for one.
    private static let folderIcon = SystemSymbol.folderFill.image
    private static let frameworkIcon = CustomSymbol.framework.image
    private static let bundleIcon = CustomSymbol.bundle.image
    private static let applicationIcon = CustomSymbol.application.image
    private static let applicationExtensionIcon = SystemSymbol.eCircleFill.image
    private static let xpcServiceIcon = SystemSymbol.wrenchAndScrewdriverFill.image
    private static let systemExtensionIcon = CustomSymbol.systemExtension.image
    private static let kernelExtensionIcon = CustomSymbol.kernelExtension.image
    private static let preferencePaneIcon = SystemSymbol.switch2.image
    private static let screenSaverIcon = SystemSymbol.sparkles.image
    private static let dynamicLibraryIcon = SystemSymbol.buildingColumnsFill.image
    private static let imageIcon = SystemSymbol.doc.image

    #if os(macOS)
    /// The kind's icon already in `iconColor`, for a view that draws an image as it is rather than
    /// tinting a template: the jump bar and its menus, the editor's tabs, the history menu. Not a
    /// template image; the palette keeps the colour dynamic, so the icon follows the appearance when
    /// it is drawn.
    public var coloredIcon: NSImage {
        Self.coloredIcons[self] ?? icon
    }

    // Made once each: every item of the jump bar's tree asks for one.
    private static let coloredIcons = Dictionary(uniqueKeysWithValues: allCases.map { kind in
        (kind, kind.icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [kind.iconColor])) ?? kind.icon)
    })
    #endif
}

extension NSUIColor {
    /// A colour of 8-bit sRGB components, as an asset catalog lists them.
    fileprivate static func sRGB(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSUIColor {
        #if os(macOS)
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        #else
        UIColor(red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
        #endif
    }

    /// A colour of 8-bit Display P3 components, as an asset catalog lists them.
    fileprivate static func displayP3(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSUIColor {
        NSUIColor(displayP3Red: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
    }
}

extension RuntimeImageNode {
    /// What this node is (`RuntimeImageKind(node:)`).
    public var kind: RuntimeImageKind {
        RuntimeImageKind(node: self)
    }
}
