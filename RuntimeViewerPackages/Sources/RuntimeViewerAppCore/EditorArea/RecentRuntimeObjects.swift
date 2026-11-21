import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings

/// One engine's recent objects: the objects its editor panes showed, most recent first, kept in
/// `AppDefaults.recentRuntimeObjectsByEngine` under the engine's key, which an empty editor pane's
/// start page lists (proposal `editor-start-page`).
///
/// An object is kept without its `children` (`listedForm(of:)`): the list only names and opens
/// objects, which identity alone does, while a nested type or a namespace can carry a tree of
/// thousands of objects that every write would encode again — the store writes the whole file
/// on every change.
///
/// Xcode's initial editor lists a workspace's recent files; a window here works on one engine, so
/// the engine is what the list belongs to, and every window on it shares the list. The key is the
/// one Always Index and the Filter Scope memory match engines by
/// (`Settings.Indexing.EngineReference.key(for:)`): a process attached on this Mac by its name, so
/// its list survives the process relaunching; any other engine by its bookmark scope.
struct RecentRuntimeObjects: Hashable, Sendable {
    /// How many objects an engine keeps; the oldest go first. Xcode keeps a workspace's ten most
    /// recent files (`IDERecentEditorDocumentsLimit` unset), of which its initial editor shows eight
    /// until Show All.
    static let maximumCount = 10

    let engineKey: String

    init(engineKey: String) {
        self.engineKey = engineKey
    }

    init(engine: RuntimeEngine) {
        self.init(engineKey: Settings.Indexing.EngineReference.key(for: engine))
    }

    /// The engine's recent objects, most recent first; none when it has no list.
    func objects(in objectsByEngine: [String: [RuntimeObject]]) -> [RuntimeObject] {
        objectsByEngine[engineKey] ?? []
    }

    /// `objectsByEngine` with `object` first in the engine's list, in its listed form, or `nil`
    /// when it is first already in that form and there is nothing to write.
    ///
    /// An object already in the list moves to the front instead of being listed twice, matched by
    /// identity (`RuntimeObject.==`), and is kept in the form it is recorded in — one whose
    /// properties changed since keeps the new ones. That is also why the answer is optional rather than a dictionary
    /// to compare: `==` on the objects is identity only, so two lists that differ only in an
    /// object's form compare equal. The list then keeps at most `maximumCount` objects.
    func recording(_ object: RuntimeObject, in objectsByEngine: [String: [RuntimeObject]]) -> [String: [RuntimeObject]]? {
        let object = Self.listedForm(of: object)
        let recentObjects = objects(in: objectsByEngine)
        if let mostRecentObject = recentObjects.first, mostRecentObject.hasSameContent(as: object) {
            return nil
        }
        var updatedObjects = recentObjects.filter { $0 != object }
        updatedObjects.insert(object, at: 0)
        if updatedObjects.count > Self.maximumCount {
            updatedObjects.removeLast(updatedObjects.count - Self.maximumCount)
        }
        var updatedObjectsByEngine = objectsByEngine
        updatedObjectsByEngine[engineKey] = updatedObjects
        return updatedObjectsByEngine
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
