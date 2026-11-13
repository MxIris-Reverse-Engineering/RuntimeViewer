#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import RuntimeViewerAppCore
import AppKitPlus
import RuntimeViewerCore

/// One node of the tree an editor pane's jump bar walks (proposal `editor-jump-bar`): the engine at
/// the top, the folders and images of its image tree under it, an image's objects under the image.
///
/// `EditorJumpBarItemStore` makes every item and keeps it for as long as the tree stands: the
/// control compares items by pointer, so a node is always the same item. The store also answers
/// `childItems`, reading a folder's children when a menu first lists them and filling in an image's
/// objects once the image is indexed; it posts the key-value change for that (`childItems` is
/// observed by the control while a submenu shows it). An object's parent can change once its
/// image's objects are known — a nested type moves under its enclosing type — which the control
/// does not observe; the store reports it so the jump bar rebuilds its path.
@MainActor
public final class EditorJumpBarItem: NSObject, NSPopUpPathItem {
    /// What an item stands for.
    public enum Content {
        /// The engine the document is on: the first component, as Xcode's project or SDK is.
        case source(RuntimeEngine)

        /// A folder of the image tree, its synthetic roots (`Dyld Shared Cache`, `Others`, an
        /// offline file's name) included.
        case folder(RuntimeImageNode)

        /// An image: a document root, chosen as a whole, whose objects follow it in the path.
        case image(path: String, node: RuntimeImageNode?)

        /// An object of an image.
        case object(RuntimeObject)
    }

    public let content: Content

    public let pathComponentName: String

    public let pathComponentIcon: NSImage?

    /// An object's kind section, so that a menu puts a separator between kinds; a nested type is in
    /// its enclosing type's. Set again when the image's objects are read.
    public internal(set) var groupIdentifier: String?

    /// Set by the store when it makes the item, and again when an object's place in its image
    /// becomes known.
    public internal(set) weak var parentItem: (any NSPopUpPathItem)?

    /// The store that answers `childItems`; the store owns its items, so this does not.
    weak var store: EditorJumpBarItemStore?

    /// Children the store has made, `nil` until it has.
    var storedChildItems: [EditorJumpBarItem]?

    init(content: Content, name: String, icon: NSImage?, groupIdentifier: String? = nil, parentItem: EditorJumpBarItem?, store: EditorJumpBarItemStore) {
        self.content = content
        self.pathComponentName = name
        self.pathComponentIcon = icon
        self.groupIdentifier = groupIdentifier
        self.parentItem = parentItem
        self.store = store
    }

    /// The children the store knows: a folder's at once, an image's objects once the image is
    /// indexed, an object's nested types.
    @objc public var childItems: [any NSPopUpPathItem]? {
        store?.childItems(of: self)
    }

    /// An object without nested types; the engine, folders and images always lead somewhere.
    public var isLeaf: Bool {
        switch content {
        case .source, .folder, .image:
            false
        case .object(let object):
            // What was read with the image's objects, which can have gained a specialization since
            // the item was made.
            storedChildItems.map(\.isEmpty) ?? object.children.isEmpty
        }
    }

    /// An image is chosen as a whole, as a file is in Xcode's jump bar: its row has no submenu, and
    /// with no object chosen the path ends in "No Selection".
    public var representsDocumentRoot: Bool {
        if case .image = content { return true }
        return false
    }

    public var pathComponentToolTip: String? {
        switch content {
        case .image(let path, _):
            path
        case .source, .folder, .object:
            nil
        }
    }

    /// The image or folder on this Mac's disk, for the control's Command-click menu of enclosing
    /// folders; `nil` for what is not on this Mac — an image of the dyld shared cache, a device's.
    public var representedFileURL: URL? {
        guard let store, store.readsThisMacsDisk else { return nil }
        let path: String
        switch content {
        case .image(let imagePath, _):
            path = imagePath
        case .folder(let node):
            guard node.parent != nil else { return nil }
            path = node.path
        case .source, .object:
            return nil
        }
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    /// Posts the key-value change of `childItems` around `update`, so an open submenu listing this
    /// item's children rebuilds.
    func updateChildItems(_ update: () -> Void) {
        willChangeValue(forKey: #keyPath(childItems))
        update()
        didChangeValue(forKey: #keyPath(childItems))
    }

    /// The image path the item stands for, or the image path of the object it stands for.
    var imagePath: String? {
        switch content {
        case .image(let path, _):
            path
        case .object(let object):
            object.imagePath
        case .source, .folder:
            nil
        }
    }

    /// The choice the item stands for in a menu: an image or an object; `nil` for the engine and a
    /// folder, which lead elsewhere and are never chosen themselves.
    var choiceTarget: EditorJumpBarChoice.Target? {
        switch content {
        case .image(let path, _):
            .image(path: path)
        case .object(let object):
            .object(object)
        case .source, .folder:
            nil
        }
    }
}

#endif
