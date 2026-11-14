import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RuntimeViewerCore

/// What a node of the image tree, or the image at a path, is — the one place every list of images
/// decides which icon a row shows (proposal `image-kind-icons`).
public enum RuntimeImageKind: Hashable, Sendable, CaseIterable {
    /// A directory that is none of the bundles below.
    case folder

    /// A `.framework`.
    case framework

    /// A loadable bundle: a `.bundle`, `.plugin`, `.xpc` or `.appex`.
    case bundle

    /// An `.app`.
    case application

    /// A `.kext`.
    case kernelExtension

    /// A dynamic library: a `.dylib`, or the binary of the framework it is in. In the image tree the
    /// file itself, and for an image path a `.dylib` in none of the bundles above.
    case dynamicLibrary

    /// Any other Mach-O file: in the image tree the file itself — the executable inside an app or a
    /// bundle, say, or a tool among a framework's resources — and for an image path one in none of
    /// the bundles above.
    case image

    /// What the Mach-O file at `imagePath` is by its own name, whatever else it is part of: a dynamic
    /// library by its extension or when it is the binary of the framework it is in — the file named
    /// like the bundle nearest to it, when that is a framework, as `AppKit.framework/Versions/C/AppKit`
    /// — otherwise an image. What a tree of paths shows for an image, where its bundle is a node of
    /// its own.
    public init(imageFileAt imagePath: String) {
        let fileName = (imagePath as NSString).lastPathComponent
        if (fileName as NSString).pathExtension == "dylib" {
            self = .dynamicLibrary
        } else if let nearestBundle = Self.nearestBundle(onPathOf: imagePath),
                  nearestBundle.kind == .framework,
                  (nearestBundle.directoryName as NSString).deletingPathExtension == fileName {
            self = .dynamicLibrary
        } else {
            self = .image
        }
    }

    /// The bundle directory on `imagePath` nearest to its file, and the kind it makes, or `nil` when
    /// the file is in none.
    private static func nearestBundle(onPathOf imagePath: String) -> (directoryName: String, kind: RuntimeImageKind)? {
        let directoryNames = (imagePath as NSString).pathComponents.dropLast()
        return directoryNames.reversed().lazy
            .compactMap { directoryName in
                Self(bundleExtension: (directoryName as NSString).pathExtension).map { (directoryName: directoryName, kind: $0) }
            }
            .first
    }

    /// The bundle kind a directory named with `pathExtension` is, or `nil` for any other directory.
    private init?(bundleExtension pathExtension: String) {
        switch pathExtension {
        case "framework":
            self = .framework
        case "bundle", "plugin", "xpc", "appex":
            self = .bundle
        case "app":
            self = .application
        case "kext":
            self = .kernelExtension
        default:
            return nil
        }
    }

    /// What `node` is, by its own name: a bundle by its extension, otherwise a leaf is a dynamic
    /// library or an image as `init(imageFileAt:)` says for its path, and any other node a folder.
    /// `AppKit.framework` is a framework; the `AppKit` inside it, its dynamic library, as is
    /// `libobjc.A.dylib`; `rapportd`, an image.
    public init(node: RuntimeImageNode) {
        if let bundleKind = Self(bundleExtension: (node.name as NSString).pathExtension) {
            self = bundleKind
        } else {
            // The absolute path, which a bookmarked node keeps without its ancestors.
            self = node.isLeaf ? Self(imageFileAt: node.absolutePath) : .folder
        }
    }

    /// What the image at `imagePath` is part of: the bundle on its path nearest to it, or, when it is
    /// in none, what the file itself is. AppKit's is a framework, `/usr/lib/libobjc.A.dylib` a dynamic
    /// library.
    public init(ofImageAt imagePath: String) {
        self = Self.nearestBundle(onPathOf: imagePath)?.kind ?? Self(imageFileAt: imagePath)
    }

    /// The kind's symbol at the system's default size, a template image, the one Xcode draws that kind
    /// of file with: its own for the bundles and an app, the system's `folder.fill` for a folder,
    /// `building.columns.fill` for a dynamic library and `terminal.fill`, Xcode's for an executable
    /// (`public.executable`), for any other image. A view that can tint a template draws it in
    /// `iconColor`, which a selected row turns white as Xcode's does; a view that draws an image as it
    /// is takes `coloredIcon`.
    public var icon: NSUIImage {
        switch self {
        case .folder: Self.folderIcon
        case .framework: Self.frameworkIcon
        case .bundle: Self.bundleIcon
        case .application: Self.applicationIcon
        case .kernelExtension: Self.kernelExtensionIcon
        case .dynamicLibrary: Self.dynamicLibraryIcon
        case .image: Self.imageIcon
        }
    }

    /// The colour Xcode draws this kind's icon in (the `Xcode.SymbolicIcon` extensions of
    /// DVTUserInterfaceKit, Xcode 27.2): a folder (`public.folder`), a bundle and a kernel extension
    /// Xcode's own light blue, a framework system yellow, a dynamic library (`com.apple.mach-o-dylib`)
    /// Xcode's steel, an app the secondary label colour — Xcode gives an app's icon no colour of its
    /// own and draws it in that one — and any other image the label colour: Xcode's `doc-text` for an
    /// executable is the label colour's light value, and the only value it has.
    public var iconColor: NSUIColor {
        switch self {
        case .folder, .bundle, .kernelExtension: Self.xcodeLightBlue
        case .framework: .systemYellow
        case .application: Self.secondaryLabelColor
        case .dynamicLibrary: Self.xcodeSteel
        case .image: Self.labelColor
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
    private static let labelColor = NSColor.labelColor
    #else
    private static let secondaryLabelColor = UIColor.secondaryLabel
    private static let labelColor = UIColor.label
    #endif

    // Loaded once each: every row of every list asks for one.
    private static let folderIcon = SystemSymbol.folderFill.image
    private static let frameworkIcon = CustomSymbol.framework.image
    private static let bundleIcon = CustomSymbol.bundle.image
    private static let applicationIcon = CustomSymbol.application.image
    private static let kernelExtensionIcon = CustomSymbol.kernelExtension.image
    private static let dynamicLibraryIcon = SystemSymbol.buildingColumnsFill.image
    private static let imageIcon = SystemSymbol.terminalFill.image

    #if os(macOS)
    /// The kind's icon already in `iconColor`, for a view that draws an image as it is rather than
    /// tinting a template: the jump bar and its menus, the editor's tabs, the history menu. Not a
    /// template image; the palette keeps the colour dynamic, so the icon follows the appearance and
    /// the accent colour when it is drawn.
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
