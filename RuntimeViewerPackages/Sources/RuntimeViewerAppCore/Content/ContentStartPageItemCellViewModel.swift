#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import RxAppKit
#endif

import Foundation
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// One row of an empty editor pane's start page: a recent object, or a match of the page's Open
/// Quickly field — an object, or an image by name (proposal `editor-start-page`). Xcode's initial
/// editor draws the same row for a recent file: the item's icon and name, and under them its path,
/// the first component's icon and every component's name.
///
/// A row never changes once made, so it carries its appearance as a plain value.
public final class ContentStartPageItemCellViewModel: NSObject, @unchecked Sendable {
    /// What the row opens.
    public enum Item: Hashable, Sendable {
        /// An object, shown in its own language.
        case object(RuntimeObject)
        /// An image, by the path its image tree node gives (`RuntimeImageNode.path`): its image page.
        case image(path: String)
    }

    public struct Appearance: Hashable, Sendable {
        public var icon: IconDescriptor
        public var title: String
        /// The icon in front of the path: the first component's.
        public var pathIcon: IconDescriptor?
        /// The path's components, joined with chevrons when drawn.
        public var pathComponents: [String]

        public init(icon: IconDescriptor, title: String, pathIcon: IconDescriptor?, pathComponents: [String]) {
            self.icon = icon
            self.title = title
            self.pathIcon = pathIcon
            self.pathComponents = pathComponents
        }
    }

    public let item: Item

    public let appearance: Appearance

    public init(item: Item, appearance: Appearance) {
        self.item = item
        self.appearance = appearance
    }

    /// A row for `item` on an engine named `engineName` (`RuntimeEngine.source.description`) whose
    /// icon is found again by `engineID`: an object under its image, an image under the folder
    /// holding it (`containingFolderName(ofImageAt:)`).
    public convenience init(item: Item, engineName: String, engineID: String) {
        let appearance: Appearance
        switch item {
        case .object(let object):
            appearance = Appearance(
                icon: .runtimeObject(object.kind, size: Self.iconSize),
                title: object.displayName,
                pathIcon: .runtimeEngine(engineID: engineID),
                pathComponents: [engineName, NavigationEntry.imageName(ofImageAt: object.imagePath)]
            )
        case .image(let path):
            appearance = Appearance(
                icon: .imageKind(RuntimeImageKind(ofImageAt: path)),
                title: NavigationEntry.imageName(ofImageAt: path),
                pathIcon: .runtimeEngine(engineID: engineID),
                pathComponents: [engineName] + [Self.containingFolderName(ofImageAt: path)].compactMap { $0 }
            )
        }
        self.init(item: item, appearance: appearance)
    }

    /// The folder an image is found in: the one holding the bundle nearest to it on its path —
    /// `Frameworks` for `/System/Library/Frameworks/AppKit.framework/Versions/C/AppKit`, never the
    /// `C` inside the bundle — or, outside any bundle, its own directory (`lib` for
    /// `/usr/lib/libobjc.A.dylib`). `nil` for an image at the root.
    static func containingFolderName(ofImageAt imagePath: String) -> String? {
        let directoryNames = Array((imagePath as NSString).pathComponents.dropLast())
        let outerDirectoryNames: ArraySlice<String>
        if let nearestBundleIndex = directoryNames.lastIndex(where: RuntimeImageKind.isBundleDirectoryName) {
            outerDirectoryNames = directoryNames[..<nearestBundleIndex]
        } else {
            outerDirectoryNames = directoryNames[...]
        }
        guard let folderName = outerDirectoryNames.last, folderName != "/" else { return nil }
        return folderName
    }

    /// The size the row's icon is drawn at.
    public static let iconSize: CGFloat = 24

    public override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ContentStartPageItemCellViewModel else { return false }
        return item == other.item && appearance == other.appearance
    }

    public override var hash: Int {
        item.hashValue
    }
}

#if canImport(AppKit) && !targetEnvironment(macCatalyst)

extension ContentStartPageItemCellViewModel: Differentiable {
    public var differenceIdentifier: Item { item }

    public func isContentEqual(to source: ContentStartPageItemCellViewModel) -> Bool {
        appearance == source.appearance
    }
}

#endif
