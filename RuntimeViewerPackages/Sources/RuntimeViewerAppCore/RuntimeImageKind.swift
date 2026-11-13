import Foundation
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

    /// The kind's symbol at the system's default size, a template image: Xcode's for the bundles, the
    /// system's `folder` and `doc` for a folder and an image.
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

    // Loaded once each: every row of every list asks for one.
    private static let folderIcon = SystemSymbol.folder.image
    private static let frameworkIcon = CustomSymbol.framework.image
    private static let bundleIcon = CustomSymbol.bundle.image
    private static let applicationIcon = CustomSymbol.application.image
    private static let kernelExtensionIcon = CustomSymbol.kernelExtension.image
    private static let imageIcon = SystemSymbol.doc.image
}

extension RuntimeImageNode {
    /// What this node is (`RuntimeImageKind(node:)`).
    public var kind: RuntimeImageKind {
        RuntimeImageKind(node: self)
    }

    /// The icon of what this node is.
    public var icon: NSUIImage {
        kind.icon
    }
}
