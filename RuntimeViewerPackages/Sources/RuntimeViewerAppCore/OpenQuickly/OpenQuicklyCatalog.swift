import Foundation
import RuntimeViewerCore

/// What an empty editor pane's Open Quickly field searches during one search: the engine's images
/// by name, and the objects of the images it has indexed, nested ones included (proposal
/// `editor-start-page`).
///
/// Xcode's initial editor searches what its Open Quickly window searches, the workspace's files and
/// symbols; an engine's images are its files and their objects its symbols. Only images already
/// indexed give their objects: their lists come from the index, and reading them indexes nothing,
/// so typing never starts work the user did not ask for. An image that is not indexed is found by
/// name, and its image page indexes it.
///
/// A catalog is read once when a search starts and dropped when it ends, so it never outlives the
/// typing it serves.
struct OpenQuicklyCatalog: Sendable {
    struct Entry: Sendable {
        let item: ContentStartPageItemCellViewModel.Item
        /// What the query is matched against: an object's display name, an image's file name.
        let name: String
    }

    let entries: [Entry]

    /// The entries' names, in the entries' order: the haystacks a match runs over.
    private let names: [String]

    init(entries: [Entry]) {
        self.entries = entries
        self.names = entries.map(\.name)
    }

    /// The images at `imagePaths` — the paths their image tree nodes give — then every object in
    /// `objectsByImagePath`, each followed by its nested objects.
    init(imagePaths: [String], objectsByImagePath: [String: [RuntimeObject]]) {
        var entries = imagePaths.map { imagePath in
            Entry(item: .image(path: imagePath), name: NavigationEntry.imageName(ofImageAt: imagePath))
        }
        for imagePath in objectsByImagePath.keys.sorted() {
            for object in objectsByImagePath[imagePath] ?? [] {
                Self.appendEntries(for: object, to: &entries)
            }
        }
        self.init(entries: entries)
    }

    private static func appendEntries(for object: RuntimeObject, to entries: inout [Entry]) {
        entries.append(Entry(item: .object(object), name: object.displayName))
        for child in object.children {
            appendEntries(for: child, to: &entries)
        }
    }

    /// The best `limit` entries matching `query`, best first, ranked as Open Quickly ranks
    /// (`OpenQuicklyRanking`). Pure; run it off the main thread.
    func matches(for query: String, limit: Int) -> [Entry] {
        guard !query.isEmpty else { return [] }
        let context = FilterContext(query: query, isCaseInsensitive: false, mode: .fuzzySearch)
        let verdicts = FilterEngine.match(context, haystacks: names)
        return OpenQuicklyRanking.rank(verdicts, limit: limit) { haystackIndex in
            names[haystackIndex]
        }
        .map { entries[$0.haystackIndex] }
    }

    /// How many images' objects are read at once.
    static let maximumConcurrentReads = 8

    /// The catalog of `engine` now: the images at `imagePaths` — the leaves of its image tree, which
    /// the caller reads on the main actor — and the objects of every image `engine` has indexed.
    /// An image whose objects cannot be read is left out; a failure to list the indexed images
    /// leaves the objects out altogether.
    static func load(imagePaths: [String], from engine: RuntimeEngine) async -> OpenQuicklyCatalog {
        let indexedImagePaths = (try? await engine.indexedImagePathList()) ?? []
        var objectsByImagePath: [String: [RuntimeObject]] = [:]
        await withTaskGroup(of: (String, [RuntimeObject]?).self) { group in
            var pendingImagePaths = indexedImagePaths[...]
            func readNextImage() {
                guard let imagePath = pendingImagePaths.popFirst() else { return }
                group.addTask {
                    (imagePath, try? await engine.objects(in: imagePath))
                }
            }
            for _ in 0 ..< maximumConcurrentReads {
                readNextImage()
            }
            for await (imagePath, objects) in group {
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                if let objects {
                    objectsByImagePath[imagePath] = objects
                }
                readNextImage()
            }
        }
        return OpenQuicklyCatalog(imagePaths: imagePaths, objectsByImagePath: objectsByImagePath)
    }
}

extension RuntimeImageNode {
    /// The paths of the images below this node, depth first: every leaf's `path`. A root without
    /// children — an empty group of the tree — is no image.
    var leafImagePaths: [String] {
        if isLeaf { return parent == nil ? [] : [path] }
        return children.flatMap(\.leafImagePaths)
    }
}
