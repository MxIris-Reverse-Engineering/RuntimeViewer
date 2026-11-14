import Foundation
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import RuntimeViewerCore

/// What a node of the image tree, or the image at a path, is — the one place every list of images
/// decides which icon a row shows (proposal `draft-image-kind-icons`).
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

    /// A Mach-O file: in the image tree the file itself, and for an image path one in none of the
    /// bundles above.
    case image

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

    /// What `node` is, by its own name: a bundle by its extension, otherwise a leaf is an image and
    /// any other node a folder. `AppKit.framework` is a framework; the `AppKit` inside it, an image.
    public init(node: RuntimeImageNode) {
        if let bundleKind = Self(bundleExtension: (node.name as NSString).pathExtension) {
            self = bundleKind
        } else {
            self = node.isLeaf ? .image : .folder
        }
    }

    /// What the image at `imagePath` is part of: the bundle on its path nearest to it, or `.image`
    /// when it is in none. AppKit's is a framework, `/usr/lib/libobjc.A.dylib` an image.
    public init(ofImageAt imagePath: String) {
        let directoryNames = (imagePath as NSString).pathComponents.dropLast()
        let nearestBundleKind = directoryNames.reversed().lazy
            .compactMap { Self(bundleExtension: ($0 as NSString).pathExtension) }
            .first
        self = nearestBundleKind ?? .image
    }

    /// The kind's symbol at the system's default size, a template image: Xcode's own for the bundles,
    /// the system's `folder.fill` for a folder as Xcode draws one, and the system's `doc` for an image.
    /// A view that can tint a template draws it in `iconColor`, which a selected row turns white as
    /// Xcode's does; a view that draws an image as it is takes `coloredIcon`.
    public var icon: NSUIImage {
        switch self {
        case .folder: Self.folderIcon
        case .framework: Self.frameworkIcon
        case .bundle: Self.bundleIcon
        case .application: Self.applicationIcon
        case .kernelExtension: Self.kernelExtensionIcon
        case .image: Self.imageIcon
        }
    }

    /// The colour Xcode draws this kind's icon in (the `Xcode.SymbolicIcon` extensions of
    /// DVTUserInterfaceKit, Xcode 27.2): a folder (`public.folder`), a bundle and a kernel extension
    /// Xcode's own light blue, a framework system yellow, and an app the secondary label colour — Xcode
    /// gives an app's icon no colour of its own and draws it in that one. An image file, which Xcode
    /// shows with another symbol, takes the accent colour.
    public var iconColor: NSUIColor {
        switch self {
        case .folder, .bundle, .kernelExtension: Self.xcodeLightBlue
        case .framework: .systemYellow
        case .application: Self.secondaryLabelColor
        case .image: Self.accentColor
        }
    }

    /// Xcode's `doc-lightBlue`: not a system colour, one value for the light appearance and one for
    /// the dark, both sRGB.
    private static let xcodeLightBlue = NSUIColor(
        light: NSUIColor.sRGB(red: 70, green: 169, blue: 255),
        dark: NSUIColor.sRGB(red: 66, green: 173, blue: 255)
    )

    #if os(macOS)
    private static let secondaryLabelColor = NSColor.secondaryLabelColor
    private static let accentColor = NSColor.controlAccentColor
    #else
    private static let secondaryLabelColor = UIColor.secondaryLabel
    private static let accentColor = UIColor.tintColor
    #endif

    // Loaded once each: every row of every list asks for one.
    private static let folderIcon = SystemSymbol.folderFill.image
    private static let frameworkIcon = CustomSymbol.framework.image
    private static let bundleIcon = CustomSymbol.bundle.image
    private static let applicationIcon = CustomSymbol.application.image
    private static let kernelExtensionIcon = CustomSymbol.kernelExtension.image
    private static let imageIcon = SystemSymbol.doc.image

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
}

extension RuntimeImageNode {
    /// What this node is (`RuntimeImageKind(node:)`).
    public var kind: RuntimeImageKind {
        RuntimeImageKind(node: self)
    }
}
