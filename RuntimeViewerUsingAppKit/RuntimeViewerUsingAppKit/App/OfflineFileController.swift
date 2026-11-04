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
/// here — File › Open…, Open Recent and the Dock alike — and the runtime source
/// picker's Open File… and Dependency Cache open and re-pair through here too.
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
    /// document controller and, when `display` is set, shown at once — while
    /// an instance of the offline service is still reading the file, which a
    /// dyld shared cache keeps busy for a while; the window says so until it
    /// has. Throws, before any window opens, when `url` is no file offline
    /// mode reads. When the instance cannot read it, the window says why and
    /// closes once the user has acknowledged it, and Open Recent does not
    /// list the file.
    func openDocument(forFileAt url: URL, display: Bool) async throws -> Document {
        let file = try await fileToRead(at: url)
        let engine = try await runtimeEngineManager.startReading(file)
        let document = Document(runtimeEngine: engine)
        NSDocumentController.shared.addDocument(document)
        if display {
            document.makeWindowControllers()
            document.showWindows()
        }
        Task { [weak self] in
            await self?.finishOpening(document, readBy: engine, from: url, named: file.displayName)
        }
        return document
    }

    /// The file at `url` as offline mode reads it: the listed one, with the
    /// cache the user paired it with, or a new one paired with the default
    /// cache. What is at `url` is inspected off the main thread — a header
    /// read, but of a file that can be anywhere, a slow volume included.
    private func fileToRead(at url: URL) async throws -> RuntimeOfflineFile {
        var file = try await Task.detached(priority: .userInitiated) {
            try RuntimeOfflineFile(contentsOf: url)
        }.value
        if let listedFile = listedFile(withSource: file.source) {
            file = listedFile
        } else {
            file.dependencyCache = settings.offline.defaultDependencyCache(for: file)
        }
        return file
    }

    /// Waits for `engine` to have read its file. Then the file joins Open
    /// Recent; or, when it could not be read, `document`'s window says why
    /// and closes once the user has acknowledged it.
    private func finishOpening(_ document: Document, readBy engine: RuntimeEngine, from url: URL, named displayName: String) async {
        do {
            try await runtimeEngineManager.waitUntilFileIsRead(by: engine)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            #log(.info, "Opened \(url.lastPathComponent, privacy: .public) offline")
        } catch {
            #log(.error, "Could not open \(url.lastPathComponent, privacy: .public) offline: \(error.localizedDescription, privacy: .public)")
            // Closed while the file was being read: nobody is waiting to hear.
            guard NSDocumentController.shared.documents.contains(where: { $0 === document }) else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "“\(displayName)” could not be read."
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            guard let window = document.windowForSheet else {
                alert.runModal()
                document.close()
                return
            }
            alert.beginSheetModal(for: window) { _ in
                document.close()
            }
        }
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

    /// Reads `engine`'s file again, paired with `dependencyCache`, and waits
    /// until it has. The engine stays the same object, so every window on it
    /// stays, saying it is reading meanwhile; its new instance lists the
    /// images anew.
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
