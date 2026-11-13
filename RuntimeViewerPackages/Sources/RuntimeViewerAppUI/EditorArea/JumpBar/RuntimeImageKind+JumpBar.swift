#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerAppCore

extension RuntimeImageKind {
    /// The colour of this kind's icon in a jump bar: a folder blue, a framework yellow and a bundle
    /// light blue, after Xcode's, and every other kind the accent colour (proposal
    /// `draft-image-kind-icons`).
    var jumpBarColor: NSColor {
        switch self {
        case .folder: .systemBlue
        case .framework: .systemYellow
        case .bundle: .systemCyan
        case .application, .kernelExtension, .image: .controlAccentColor
        }
    }

    /// This kind's icon in its jump bar colour. Not a template image, so AppKitPlus's path control
    /// draws it as it is instead of in the text colour — in the path and in the menus alike.
    var jumpBarIcon: NSImage {
        switch self {
        case .folder: Self.folderJumpBarIcon
        case .framework: Self.frameworkJumpBarIcon
        case .bundle: Self.bundleJumpBarIcon
        case .application: Self.applicationJumpBarIcon
        case .kernelExtension: Self.kernelExtensionJumpBarIcon
        case .image: Self.imageJumpBarIcon
        }
    }

    // Made once each: every item of the tree asks for one. The palette keeps the colours dynamic, so
    // an icon follows the appearance and the accent colour when it is drawn.
    private static let folderJumpBarIcon = RuntimeImageKind.folder.makeJumpBarIcon()
    private static let frameworkJumpBarIcon = RuntimeImageKind.framework.makeJumpBarIcon()
    private static let bundleJumpBarIcon = RuntimeImageKind.bundle.makeJumpBarIcon()
    private static let applicationJumpBarIcon = RuntimeImageKind.application.makeJumpBarIcon()
    private static let kernelExtensionJumpBarIcon = RuntimeImageKind.kernelExtension.makeJumpBarIcon()
    private static let imageJumpBarIcon = RuntimeImageKind.image.makeJumpBarIcon()

    private func makeJumpBarIcon() -> NSImage {
        icon.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [jumpBarColor])) ?? icon
    }
}

#endif
