#if canImport(AppKit) && !targetEnvironment(macCatalyst)

import AppKit
import Dependencies
import RuntimeViewerCore
import RuntimeViewerArchitectures

/// The tree every editor pane's jump bar of one document walks (proposal `editor-jump-bar`): the
/// document's engine, its image tree, and the objects of the images the jump bars have shown.
///
/// One per document, shared by its panes: an item is the same object in every pane, as the control
/// needs it to be for as long as it shows it. The tree follows the document's engine — a new engine
/// or a new image list makes it again and says so (`treeRebuilt`), and every jump bar shows its
/// location again from the new items.
///
/// **Objects are read only for images a jump bar has shown, and only once they are indexed.** The
/// jump bar never indexes anything itself: the content pane does, for the image page and for an
/// object of an image that is not indexed yet, and the store reads the objects when the engine
/// reports the image indexed. An image's object list does not change while it stays indexed but for
/// a specialization added to one of its types, which reads it again.
@MainActor
public final class EditorJumpBarItemStore {
    /// What the first component lists: the engine alone; none before the document has one.
    public private(set) var rootItems: [EditorJumpBarItem] = []

    /// The tree was made again, from another engine or another image list: every item is new.
    public var treeRebuilt: Signal<Void> {
        treeRebuiltRelay.asSignal()
    }

    /// Objects moved under other parents once their image's objects were read — a nested type the
    /// path first showed under the image itself — which the control does not observe.
    public var itemsMoved: Signal<Void> {
        itemsMovedRelay.asSignal()
    }

    /// Whether the engine reads its images from this Mac's disk, so that a path can be revealed in
    /// Finder (`EditorJumpBarItem.representedFileURL`).
    private(set) var readsThisMacsDisk = false

    private enum ObjectListState {
        /// Asked for while the image was not indexed: read once the engine reports it indexed.
        case waitingForIndex

        case reading

        case read
    }

    private var engine: RuntimeEngine?

    /// The image tree's roots, kept here as well: a node holds its parent weakly.
    private var rootNodes: [RuntimeImageNode] = []

    private var sourceItem: EditorJumpBarItem?

    private var nodeItemsByNode: [ObjectIdentifier: EditorJumpBarItem] = [:]

    /// Every image of the tree by the engine's canonical form of its path, made the first time an
    /// image is looked up.
    private var imageNodesByCanonicalPath: [String: RuntimeImageNode]?

    /// Items of images the tree does not list — an image an object came from that is in no node.
    private var unlistedImageItemsByCanonicalPath: [String: EditorJumpBarItem] = [:]

    /// The object items of each image, by canonical image path: those read with the image's objects,
    /// and the ones a jump bar asked for before they were read.
    private var objectItemsByCanonicalImagePath: [String: [RuntimeObject: EditorJumpBarItem]] = [:]

    private var objectListStatesByCanonicalImagePath: [String: ObjectListState] = [:]

    /// Images the engine reported indexed while their objects were being read: a read that found
    /// such an image not indexed asked before the indexing ended, and reads again.
    private var imagesIndexedWhileReading: Set<String> = []

    /// Bumped whenever the tree is made again, so a read that started before is dropped.
    private var treeGeneration = 0

    private let treeRebuiltRelay = PublishRelay<Void>()

    private let itemsMovedRelay = PublishRelay<Void>()

    private var engineDisposeBag = DisposeBag()

    private let disposeBag = DisposeBag()

    /// A store following `documentState`'s engine, from the engine it is on now.
    public init(documentState: DocumentState) {
        // The session changes on the main actor and the tree has to follow before anything asks
        // for an item, so this runs where the change is delivered rather than a turn later.
        documentState.$runtimeEngineSession.asObservable()
            .map(\.engine)
            .subscribeOnNext { [weak self] engine in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.follow(engine)
                }
            }
            .disposed(by: disposeBag)
    }

    // MARK: - Items for locations

    /// The item at the end of the path to `location`, made if it has to be; `nil` for nothing.
    ///
    /// For an image or an object, the image's objects are read if they are not, so the component
    /// after the image lists them.
    public func item(for location: EditorJumpBarLocation) -> EditorJumpBarItem? {
        switch location {
        case .nothing:
            return nil
        case .image(let path):
            guard let imageItem = imageItem(forImageAt: path) else { return nil }
            readObjects(of: imageItem)
            return imageItem
        case .object(let object):
            guard let imageItem = imageItem(forImageAt: object.imagePath) else { return nil }
            readObjects(of: imageItem)
            return objectItem(for: object, in: imageItem)
        }
    }

    /// `item`'s children: the image tree's roots under the engine, a folder's children by name, an
    /// image's objects once they are read — reading them if nobody has asked — and an object's
    /// nested types.
    func childItems(of item: EditorJumpBarItem) -> [EditorJumpBarItem]? {
        if let storedChildItems = item.storedChildItems {
            return storedChildItems
        }
        switch item.content {
        case .source:
            let childItems = rootNodes.map { nodeItem(for: $0) }
            item.storedChildItems = childItems
            return childItems
        case .folder(let node):
            let childItems = node.children
                .sorted { $0.name < $1.name }
                .map { nodeItem(for: $0) }
            item.storedChildItems = childItems
            return childItems
        case .image:
            readObjects(of: item)
            return nil
        case .object:
            return nil
        }
    }

    // MARK: - Following the engine

    /// Follows `engine` from now on: its image list makes the tree, its index reports read the
    /// objects waiting for them, a specialization reads its image's objects again. The same engine
    /// again — the document starting over on it — makes the tree again too, from the image list it
    /// sends as it is subscribed to.
    private func follow(_ engine: RuntimeEngine) {
        engineDisposeBag = DisposeBag()
        self.engine = engine
        readsThisMacsDisk = SidebarRootViewModel.isOnThisMac(engine.source)
        sourceItem = nil

        // The engine publishes from its own executor; the tree is the main actor's.
        engine.imageNodesPublisher.asObservable()
            .observe(on: MainScheduler.instance)
            .subscribeOnNext { [weak self, weak engine] imageNodes in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.rebuildTree(on: engine, rootNodes: imageNodes)
                }
            }
            .disposed(by: engineDisposeBag)

        engine.imageDidIndexPublisher.asObservable()
            .observe(on: MainScheduler.instance)
            .subscribeOnNext { [weak self, weak engine] imagePath in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    self.imageDidIndex(at: imagePath)
                }
            }
            .disposed(by: engineDisposeBag)

        engine.dataChangePublisher.asObservable()
            .observe(on: MainScheduler.instance)
            .subscribeOnNext { [weak self, weak engine] change in
                MainActor.assumeIsolated {
                    guard let self, let engine, self.engine === engine else { return }
                    if case .specializationAdded(let parent, _) = change {
                        self.readObjectsAgain(ofImageAt: parent.imagePath)
                    }
                }
            }
            .disposed(by: engineDisposeBag)
    }

    /// Makes the tree again from `rootNodes`, unless they are the roots it already has.
    private func rebuildTree(on engine: RuntimeEngine, rootNodes: [RuntimeImageNode]) {
        let isSameTree = sourceItem != nil
            && rootNodes.count == self.rootNodes.count
            && zip(rootNodes, self.rootNodes).allSatisfy { $0 === $1 }
        guard !isSameTree else { return }
        treeGeneration &+= 1
        self.rootNodes = rootNodes
        nodeItemsByNode = [:]
        imageNodesByCanonicalPath = nil
        unlistedImageItemsByCanonicalPath = [:]
        objectItemsByCanonicalImagePath = [:]
        objectListStatesByCanonicalImagePath = [:]
        imagesIndexedWhileReading = []
        let sourceItem = EditorJumpBarItem(
            content: .source(engine),
            name: engine.source.description,
            icon: Self.icon(for: engine),
            parentItem: nil,
            store: self
        )
        self.sourceItem = sourceItem
        rootItems = [sourceItem]
        treeRebuiltRelay.accept(())
    }

    private static func icon(for engine: RuntimeEngine) -> NSImage? {
        @Dependency(\.runtimeEngineIconProvider) var runtimeEngineIconProvider
        return runtimeEngineIconProvider.icon(for: engine)
    }

    // MARK: - Image tree

    private func nodeItem(for node: RuntimeImageNode) -> EditorJumpBarItem {
        if let item = nodeItemsByNode[ObjectIdentifier(node)] {
            return item
        }
        let parentItem = node.parent.map { nodeItem(for: $0) } ?? sourceItem
        let content: EditorJumpBarItem.Content = node.isLeaf ? .image(path: node.path, node: node) : .folder(node)
        let item = EditorJumpBarItem(content: content, name: node.name, icon: node.icon, parentItem: parentItem, store: self)
        nodeItemsByNode[ObjectIdentifier(node)] = item
        return item
    }

    /// The item of the image at `imagePath`: its node's, or one under the engine for an image the
    /// tree does not list. `nil` before the document has an engine.
    private func imageItem(forImageAt imagePath: String) -> EditorJumpBarItem? {
        guard let engine, let sourceItem else { return nil }
        let canonicalPath = engine.canonicalImagePath(imagePath)
        if imageNodesByCanonicalPath == nil {
            var imageNodesByCanonicalPath: [String: RuntimeImageNode] = [:]
            for rootNode in rootNodes {
                for node in rootNode where node.isLeaf && node.parent != nil {
                    imageNodesByCanonicalPath[engine.canonicalImagePath(node.path)] = node
                }
            }
            self.imageNodesByCanonicalPath = imageNodesByCanonicalPath
        }
        if let node = imageNodesByCanonicalPath?[canonicalPath] {
            return nodeItem(for: node)
        }
        if let item = unlistedImageItemsByCanonicalPath[canonicalPath] {
            return item
        }
        let item = EditorJumpBarItem(
            content: .image(path: imagePath, node: nil),
            name: NavigationEntry.imageName(ofImageAt: imagePath),
            icon: RuntimeImageNode.imageIcon,
            parentItem: sourceItem,
            store: self
        )
        unlistedImageItemsByCanonicalPath[canonicalPath] = item
        return item
    }

    // MARK: - Objects

    /// The item of `object` in `imageItem`: the one made when the image's objects were read, or one
    /// right under the image until they are — read later, the object keeps that item, moved under
    /// its enclosing type when it has one.
    private func objectItem(for object: RuntimeObject, in imageItem: EditorJumpBarItem) -> EditorJumpBarItem? {
        guard let engine, let imagePath = imageItem.imagePath else { return nil }
        let canonicalImagePath = engine.canonicalImagePath(imagePath)
        if let item = objectItemsByCanonicalImagePath[canonicalImagePath]?[object] {
            return item
        }
        let item = makeObjectItem(for: object, parentItem: imageItem, groupIdentifier: Self.groupIdentifier(of: object.kind))
        objectItemsByCanonicalImagePath[canonicalImagePath, default: [:]][object] = item
        return item
    }

    private func makeObjectItem(for object: RuntimeObject, parentItem: EditorJumpBarItem, groupIdentifier: String) -> EditorJumpBarItem {
        EditorJumpBarItem(
            content: .object(object),
            name: object.displayName,
            icon: RuntimeObjectIcon.icon(for: object.kind, size: 16),
            groupIdentifier: groupIdentifier,
            parentItem: parentItem,
            store: self
        )
    }

    /// Reads `imageItem`'s objects unless they are read, being read, or waiting for the image to be
    /// indexed.
    private func readObjects(of imageItem: EditorJumpBarItem) {
        guard let engine, let imagePath = imageItem.imagePath else { return }
        let canonicalImagePath = engine.canonicalImagePath(imagePath)
        guard objectListStatesByCanonicalImagePath[canonicalImagePath] == nil else { return }
        startReadingObjects(of: imageItem, imagePath: imagePath, canonicalImagePath: canonicalImagePath, on: engine)
    }

    private func startReadingObjects(of imageItem: EditorJumpBarItem, imagePath: String, canonicalImagePath: String, on engine: RuntimeEngine) {
        objectListStatesByCanonicalImagePath[canonicalImagePath] = .reading
        let treeGeneration = treeGeneration
        Task { [weak self, engine] in
            // Indexed only: reading the objects of an image that is not would index it, which is
            // the content pane's to start, with its progress where the user is looking.
            let isIndexed = (try? await engine.isImageIndexed(path: imagePath)) ?? false
            let objects: [RuntimeObject]? = isIndexed ? try? await engine.objects(in: imagePath) : nil
            guard let self, self.treeGeneration == treeGeneration else { return }
            let wasIndexedWhileReading = imagesIndexedWhileReading.remove(canonicalImagePath) != nil
            guard let objects else {
                // Indexed between the question and now: the report came while this read was under
                // way and waits for nothing, so read again rather than wait for a report that has
                // already gone by.
                if wasIndexedWhileReading {
                    startReadingObjects(of: imageItem, imagePath: imagePath, canonicalImagePath: canonicalImagePath, on: engine)
                } else {
                    objectListStatesByCanonicalImagePath[canonicalImagePath] = .waitingForIndex
                }
                return
            }
            install(objects, in: imageItem, canonicalImagePath: canonicalImagePath)
            objectListStatesByCanonicalImagePath[canonicalImagePath] = .read
        }
    }

    private func imageDidIndex(at imagePath: String) {
        guard let engine else { return }
        let canonicalImagePath = engine.canonicalImagePath(imagePath)
        switch objectListStatesByCanonicalImagePath[canonicalImagePath] {
        case .waitingForIndex?:
            guard let imageItem = imageItem(forImageAt: imagePath) else { return }
            startReadingObjects(of: imageItem, imagePath: imagePath, canonicalImagePath: canonicalImagePath, on: engine)
        case .reading?:
            imagesIndexedWhileReading.insert(canonicalImagePath)
        case .read?, nil:
            break
        }
    }

    /// Reads an image's objects again after a type of it gained a specialization, if they were read.
    private func readObjectsAgain(ofImageAt imagePath: String) {
        guard let engine else { return }
        let canonicalImagePath = engine.canonicalImagePath(imagePath)
        guard objectListStatesByCanonicalImagePath[canonicalImagePath] == .read,
              let imageItem = imageItem(forImageAt: imagePath)
        else { return }
        startReadingObjects(of: imageItem, imagePath: imagePath, canonicalImagePath: canonicalImagePath, on: engine)
    }

    /// Makes `imageItem`'s children from `objects`, keeping the item every object already has, and
    /// tells the control: the image's children change, and objects that moved are reported.
    private func install(_ objects: [RuntimeObject], in imageItem: EditorJumpBarItem, canonicalImagePath: String) {
        var previousItems = objectItemsByCanonicalImagePath[canonicalImagePath] ?? [:]
        var items: [RuntimeObject: EditorJumpBarItem] = [:]
        var didMoveAnItem = false

        func makeItems(for objects: [RuntimeObject], parentItem: EditorJumpBarItem, groupIdentifier: String?) -> [EditorJumpBarItem] {
            objects.map { object in
                // Nested types are listed inline under their enclosing type, in its group, so no
                // separator falls between them.
                let itemGroupIdentifier = groupIdentifier ?? Self.groupIdentifier(of: object.kind)
                let item: EditorJumpBarItem
                if let previousItem = previousItems.removeValue(forKey: object) {
                    item = previousItem
                    if item.parentItem !== parentItem {
                        item.parentItem = parentItem
                        didMoveAnItem = true
                    }
                    item.groupIdentifier = itemGroupIdentifier
                } else {
                    item = makeObjectItem(for: object, parentItem: parentItem, groupIdentifier: itemGroupIdentifier)
                }
                items[object] = item
                item.storedChildItems = makeItems(for: object.children.sorted(), parentItem: item, groupIdentifier: itemGroupIdentifier)
                return item
            }
        }

        let topLevelItems = makeItems(for: Self.menuOrder(of: objects), parentItem: imageItem, groupIdentifier: nil)
        objectItemsByCanonicalImagePath[canonicalImagePath] = items
        imageItem.updateChildItems {
            imageItem.storedChildItems = topLevelItems
        }
        if didMoveAnItem {
            itemsMovedRelay.accept(())
        }
    }

    /// The order an image's objects are listed in: by kind, in the order of the sidebar's kind
    /// sections, each kind by name — the sidebar's order.
    static func menuOrder(of objects: [RuntimeObject]) -> [RuntimeObject] {
        var orderedKinds: [RuntimeObjectKind] = []
        var objectsByKind: [RuntimeObjectKind: [RuntimeObject]] = [:]
        for object in objects.sorted() {
            if objectsByKind[object.kind] == nil {
                orderedKinds.append(object.kind)
            }
            objectsByKind[object.kind, default: []].append(object)
        }
        return orderedKinds.sorted().flatMap { objectsByKind[$0] ?? [] }
    }

    /// The menu group of a top-level object of `kind`: a separator falls between two kinds.
    static func groupIdentifier(of kind: RuntimeObjectKind) -> String {
        String(describing: kind)
    }
}

#endif
