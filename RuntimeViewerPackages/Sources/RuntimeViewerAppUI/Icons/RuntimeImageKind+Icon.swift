import Foundation
import RuntimeViewerAppCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// How each kind of image is drawn: RuntimeViewerAppCore names the kind (`IconDescriptor.imageKind(_:)`,
/// `ColorDescriptor.imageKind(_:)`) and this extension picks its symbol and colour, the one place either is
/// chosen (proposal `app-core-without-ui-models`).
extension RuntimeImageKind {
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
