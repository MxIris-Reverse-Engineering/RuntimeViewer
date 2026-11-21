import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings

/// One engine's recent images, most recent first, each with the objects of it the editor panes
/// showed, kept in `AppDefaults.recentRuntimeImagesByEngine` under the engine's key. An empty editor
/// pane's start page lists the images while the sidebar is at its image list, and the recent
/// objects of the image the sidebar is in once it is in one (proposal `editor-start-page`).
///
/// The sidebar's image list is the outside of an engine and an image its inside, as Xcode's welcome
/// window lists recent projects and a project's initial editor the project's recent files. An image
/// counts as used when the sidebar goes into it, when an editor pane shows its image page and when
/// one shows an object of it.
///
/// An object is kept without its `children` (`listedForm(of:)`): the list only names and opens
/// objects, which identity alone does, while a nested type or a namespace can carry a tree of
/// thousands of objects that every write would encode again — the store writes the whole file on
/// every change. An image dropped from the list takes its objects with it, so an engine's list
/// holds at most `maximumImageCount` times `maximumObjectCountPerImage` objects.
///
/// The key is the one Always Index and the Filter Scope memory match engines by
/// (`Settings.Indexing.EngineReference.key(for:)`): a process attached on this Mac by its name, so
/// its list survives the process relaunching; any other engine by its bookmark scope.
struct RecentRuntimeImages: Hashable, Sendable {
    /// How many images an engine keeps; the oldest go first. Xcode keeps ten recent projects
    /// (`NSDocumentController.maximumRecentDocumentCount`).
    static let maximumImageCount = 10

    /// How many objects an image keeps; the oldest go first. Xcode keeps a workspace's ten most
    /// recent files (`IDERecentEditorDocumentsLimit` unset), of which its initial editor shows
    /// eight until Show All.
    static let maximumObjectCountPerImage = 10

    let engineKey: String

    init(engineKey: String) {
        self.engineKey = engineKey
    }

    init(engine: RuntimeEngine) {
        self.init(engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }

    /// The engine's recent images, most recent first; none when it has no list.
    func images(in imagesByEngine: [String: [RecentRuntimeImage]]) -> [RecentRuntimeImage] {
        imagesByEngine[engineKey] ?? []
    }

    /// The recent objects of the image at `imagePath` — a path in canonical form — most recent
    /// first; none when the image is not in the list.
    func objects(ofImageAt imagePath: String, in imagesByEngine: [String: [RecentRuntimeImage]]) -> [RuntimeObject] {
        images(in: imagesByEngine).first { $0.imagePath == imagePath }?.objects ?? []
    }

    /// `imagesByEngine` with `object` first in its image, in its listed form, and its image first in
    /// the engine's list, or `nil` when both are first already, the object in that form, and there
    /// is nothing to write.
    ///
    /// An object already in its image's list moves to the front instead of being listed twice,
    /// matched by identity (`RuntimeObject.==`), and is kept in the form it is recorded in — one
    /// whose properties changed since keeps the new ones. That is also why the answer is optional
    /// rather than a dictionary to compare: `==` on the objects is identity only, so two lists that
    /// differ only in an object's form compare equal.
    ///
    /// An object with no image path records nothing: it would list as an image without a name.
    func recording(_ object: RuntimeObject, in imagesByEngine: [String: [RecentRuntimeImage]]) -> [String: [RecentRuntimeImage]]? {
        guard !object.imagePath.isEmpty else { return nil }
        let object = Self.listedForm(of: object)
        let recentImages = images(in: imagesByEngine)
        if let mostRecentImage = recentImages.first, mostRecentImage.imagePath == object.imagePath,
           let mostRecentObject = mostRecentImage.objects.first, mostRecentObject.hasSameContent(as: object) {
            return nil
        }
        var updatedObjects = objects(ofImageAt: object.imagePath, in: imagesByEngine).filter { $0 != object }
        updatedObjects.insert(object, at: 0)
        if updatedObjects.count > Self.maximumObjectCountPerImage {
            updatedObjects.removeLast(updatedObjects.count - Self.maximumObjectCountPerImage)
        }
        return putting(RecentRuntimeImage(imagePath: object.imagePath, objects: updatedObjects), firstIn: imagesByEngine)
    }

    /// `imagesByEngine` with the image at `imagePath` — a path in canonical form — first in the
    /// engine's list, keeping the objects it has, or `nil` when it is first already or the path is
    /// empty.
    func recordingImage(at imagePath: String, in imagesByEngine: [String: [RecentRuntimeImage]]) -> [String: [RecentRuntimeImage]]? {
        let recentImages = images(in: imagesByEngine)
        guard !imagePath.isEmpty, recentImages.first?.imagePath != imagePath else { return nil }
        let image = recentImages.first { $0.imagePath == imagePath } ?? RecentRuntimeImage(imagePath: imagePath)
        return putting(image, firstIn: imagesByEngine)
    }

    /// `imagesByEngine` with every entry filed under another spelling of the image at `imagePath` —
    /// a path `canonicalImagePath` turns into `imagePath` — folded into the image's entry, or `nil`
    /// when no such entry is filed. The folded entry takes the place of the most recent of them,
    /// with the objects of the more recent first, up to `maximumObjectCountPerImage`.
    ///
    /// An engine learns how its peer spells paths only after it connects — a process in the iOS
    /// Simulator prefixes its `DYLD_ROOT_PATH`, which the sidebar's paths leave out — so an image
    /// filed before then is filed under the other spelling, while its objects carry the peer's
    /// spelling from the start. Only entries that come to `imagePath` are touched, never respelled
    /// otherwise: engines that share a key — two simulator processes of one name on different
    /// runtimes — spell each other's paths as something else, and respelling those would only
    /// stack one root on another.
    func foldingOtherSpellings(
        of imagePath: String,
        in imagesByEngine: [String: [RecentRuntimeImage]],
        canonicalImagePath: (String) -> String
    ) -> [String: [RecentRuntimeImage]]? {
        let recentImages = images(in: imagesByEngine)
        let spellingIndices = recentImages.indices.filter { index in
            let filedImagePath = recentImages[index].imagePath
            return filedImagePath == imagePath || canonicalImagePath(filedImagePath) == imagePath
        }
        guard let mostRecentIndex = spellingIndices.first,
              spellingIndices.contains(where: { recentImages[$0].imagePath != imagePath }) else { return nil }
        var foldedObjects: [RuntimeObject] = []
        for index in spellingIndices {
            foldedObjects += recentImages[index].objects.filter { !foldedObjects.contains($0) }
        }
        var updatedImages = recentImages
        updatedImages[mostRecentIndex] = RecentRuntimeImage(imagePath: imagePath, objects: Array(foldedObjects.prefix(Self.maximumObjectCountPerImage)))
        for index in spellingIndices.dropFirst().reversed() {
            updatedImages.remove(at: index)
        }
        var updatedImagesByEngine = imagesByEngine
        updatedImagesByEngine[engineKey] = updatedImages
        return updatedImagesByEngine
    }

    /// `imagesByEngine` with `image` first in the engine's list, in place of the entry for its path,
    /// and the list cut to `maximumImageCount`.
    private func putting(_ image: RecentRuntimeImage, firstIn imagesByEngine: [String: [RecentRuntimeImage]]) -> [String: [RecentRuntimeImage]] {
        var updatedImages = images(in: imagesByEngine).filter { $0.imagePath != image.imagePath }
        updatedImages.insert(image, at: 0)
        if updatedImages.count > Self.maximumImageCount {
            updatedImages.removeLast(updatedImages.count - Self.maximumImageCount)
        }
        var updatedImagesByEngine = imagesByEngine
        updatedImagesByEngine[engineKey] = updatedImages
        return updatedImagesByEngine
    }

    /// `object` as the list keeps it: everything but its `children`.
    static func listedForm(of object: RuntimeObject) -> RuntimeObject {
        guard !object.children.isEmpty else { return object }
        return object.withChildren([])
    }

    /// Whether two lists name the same objects in the same forms, which `==` on the lists does not
    /// tell: it compares objects by identity alone.
    static func listsAreAlike(_ firstObjects: [RuntimeObject], _ secondObjects: [RuntimeObject]) -> Bool {
        firstObjects.elementsEqual(secondObjects) { $0.hasSameContent(as: $1) }
    }
}
