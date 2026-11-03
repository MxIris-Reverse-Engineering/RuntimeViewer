import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerApplication
import RuntimeViewerEngineManagement
import RuntimeViewerSettings
import Dependencies
import DependenciesMacros

/// Opens a Mach-O file, a bundle or a dyld shared cache offline: in a window on
/// an engine that reads it, in an instance of the offline service of its own.
///
/// `DocumentController` hands every file that is not a RuntimeViewer document
/// here — File › Open…, Open Recent and the Dock alike — and the engine menu's
/// Offline Files section opens and re-pairs through here too.
@Loggable
@MainActor
final class OfflineFileController {
    fileprivate static let shared = OfflineFileController()

    /// The filename extension of a RuntimeViewer document, the one kind of file
    /// not opened offline.
    private static let documentFilenameExtension = "runtimedocument"

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.settings) private var settings

    @Dependency(\.runtimeOfflineEngineParking) private var runtimeOfflineEngineParking

    private init() {}

    /// Lets an offline engine's process go while no window is on it.
    func start() {
        runtimeOfflineEngineParking.start()
    }

    /// Whether `url` is opened offline rather than as a RuntimeViewer document.
    func opensFile(at url: URL) -> Bool {
        url.pathExtension.lowercased() != Self.documentFilenameExtension
    }

    /// A new document on the engine reading the file at `url`, added to the
    /// document controller and, when `display` is set, shown.
    func openDocument(forFileAt url: URL, display: Bool) async throws -> Document {
        let engine = try await runtimeEngine(forFileAt: url)
        let document = Document(runtimeEngine: engine)
        NSDocumentController.shared.addDocument(document)
        if display {
            document.makeWindowControllers()
            document.showWindows()
        }
        #log(.info, "Opened \(url.lastPathComponent, privacy: .public) offline")
        return document
    }

    /// The engine reading the file at `url`: the listed one, with the cache
    /// the user paired it with, or a new one paired with the default cache.
    func runtimeEngine(forFileAt url: URL) async throws -> RuntimeEngine {
        var file = try RuntimeOfflineFile(contentsOf: url)
        if let listedFile = listedFile(withSource: file.source) {
            file = listedFile
        } else {
            file.dependencyCache = settings.offline.defaultDependencyCache(for: file)
        }
        return try await runtimeEngineManager.runtimeEngine(reading: file)
    }

    // MARK: - Dependency cache

    /// One entry of an offline engine's Dependency Cache menu.
    struct DependencyCacheChoice {
        let title: String
        let dependencyCache: RuntimeOfflineFile.DependencyCache?
        let isCurrent: Bool
    }

    /// What `engine`'s file can read its dependencies from: this Mac's cache
    /// for a macOS or Mac Catalyst file, the registered caches of its
    /// platform, and nothing — the file alone. Empty for a dyld shared cache,
    /// which is its own.
    func dependencyCacheChoices(for engine: RuntimeEngine) -> [DependencyCacheChoice] {
        guard let file = runtimeEngineManager.offlineFile(of: engine) else { return [] }
        if case .dyldSharedCache = file.content { return [] }
        var choices: [DependencyCacheChoice] = []
        if let platform = file.platform, Settings.Offline.platformNamesPairedWithThisMac.contains(platform.name) {
            choices.append(DependencyCacheChoice(title: "This Mac's Dyld Shared Cache", dependencyCache: .systemDyldSharedCache, isCurrent: file.dependencyCache == .systemDyldSharedCache))
        }
        for cache in settings.offline.dependencyCaches(forPlatformNamed: file.platform?.name ?? "") {
            let dependencyCache = RuntimeOfflineFile.DependencyCache.dyldSharedCache(URL(fileURLWithPath: cache.path))
            choices.append(DependencyCacheChoice(title: "\(cache.version) (\(cache.architecture)) — \(URL(fileURLWithPath: cache.path).deletingLastPathComponent().lastPathComponent)", dependencyCache: dependencyCache, isCurrent: file.dependencyCache == dependencyCache))
        }
        choices.append(DependencyCacheChoice(title: "None", dependencyCache: nil, isCurrent: file.dependencyCache == nil))
        return choices
    }

    /// Reads `engine`'s file again, paired with `dependencyCache`. The engine
    /// stays the same object, so every window on it stays; its new instance
    /// lists the images anew.
    func pair(_ engine: RuntimeEngine, with dependencyCache: RuntimeOfflineFile.DependencyCache?) async throws {
        guard var file = runtimeEngineManager.offlineFile(of: engine), file.dependencyCache != dependencyCache else { return }
        file.dependencyCache = dependencyCache
        _ = try await runtimeEngineManager.runtimeEngine(reading: file)
        #log(.info, "Paired \(file.displayName, privacy: .public) with another dependency cache")
    }

    private func listedFile(withSource source: RuntimeSource) -> RuntimeOfflineFile? {
        for engine in runtimeEngineManager.offlineRuntimeEngines where engine.source == source {
            return runtimeEngineManager.offlineFile(of: engine)
        }
        return nil
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { OfflineFileController.shared })
    var offlineFileController: OfflineFileController
}
