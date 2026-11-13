import Foundation
import RuntimeViewerCore
import RuntimeViewerSettings

/// Where one image's Filter Scope is remembered: the engine's key and the
/// image's path.
///
/// The sidebar builds an image's object pages anew every time the image is
/// opened, so a scope that lived only in the page's view model was gone the
/// next time, and the list page and the bookmarks page of one image each had
/// one of their own. It is kept in
/// `AppDefaults.runtimeObjectScopesByEngineAndImagePath` instead, and every
/// page that shows the image — both pages, in any window — reads and writes
/// the same entry.
///
/// The engine key is the one Always Index matches engines by
/// (`Settings.Indexing.EngineReference.key(for:)`): a process attached on this
/// Mac is known by its name, so its scopes survive the process relaunching,
/// which a filter the user set should; any other engine by its bookmark scope.
struct RuntimeObjectScopeMemory: Hashable, Sendable {
    let engineKey: String

    let imagePath: String

    init(engineKey: String, imagePath: String) {
        self.engineKey = engineKey
        self.imagePath = imagePath
    }

    init(engine: RuntimeEngine, imagePath: String) {
        self.init(engineKey: Settings.Indexing.EngineReference.key(for: engine), imagePath: imagePath)
    }

    /// The scope remembered for the image; the empty scope when there is none.
    func scope(in scopesByEngineAndImagePath: [String: [String: RuntimeObjectScope]]) -> RuntimeObjectScope {
        scopesByEngineAndImagePath[engineKey]?[imagePath] ?? RuntimeObjectScope()
    }

    /// `scopesByEngineAndImagePath` with `scope` remembered for the image.
    ///
    /// Only a scope that narrows the list is kept: an inactive one removes the
    /// image's entry, and the engine's once it has no image left, so the store
    /// never holds more than the scopes the user actually set.
    func remembering(
        _ scope: RuntimeObjectScope,
        in scopesByEngineAndImagePath: [String: [String: RuntimeObjectScope]]
    ) -> [String: [String: RuntimeObjectScope]] {
        var updatedScopesByEngineAndImagePath = scopesByEngineAndImagePath
        var scopesByImagePath = updatedScopesByEngineAndImagePath[engineKey] ?? [:]
        scopesByImagePath[imagePath] = scope.isActive ? scope : nil
        updatedScopesByEngineAndImagePath[engineKey] = scopesByImagePath.isEmpty ? nil : scopesByImagePath
        return updatedScopesByEngineAndImagePath
    }
}
