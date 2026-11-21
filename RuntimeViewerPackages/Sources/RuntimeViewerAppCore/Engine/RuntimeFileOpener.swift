import Foundation
import FoundationToolbox
import Dependencies
import DependenciesMacros
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerEngineManagement
import RuntimeViewerSettings

/// Opens Mach-O files, bundles, folders and dyld shared caches from disk into
/// engines that read them, on every platform: what the Mac's File › Open… and
/// the iOS apps' open button share. Showing a window on the engine, and
/// saying why a file could not be read, stay with each front end.
///
/// A file the user picked from outside the app's sandbox arrives as a
/// security-scoped URL. Its access is held for as long as the engine reads
/// the file — a folder's images are opened one at a time, when first asked
/// for, so the access cannot end once the file is first read — and ends when
/// the engine is let go (``letGoOfFile(readBy:)``).
@Loggable
@MainActor
public final class RuntimeFileOpener {
    fileprivate static let shared = RuntimeFileOpener()

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.settings) private var settings

    /// The security-scoped URLs whose access is held, by the source of the
    /// engine reading them.
    private var accessedURLsBySource: [RuntimeSource: URL] = [:]

    init() {}

    /// Starts reading the file at `url` and returns the engine reading it:
    /// the one listed for it, as the user paired it, or a new one paired with
    /// the default dependency cache. What is at `url` is inspected off the
    /// main actor — a header read, but of a file that can be anywhere, a slow
    /// volume included.
    ///
    /// Throws, opening nothing, when `url` is nothing file mode reads, and —
    /// where files are read in this process — when the file cannot be read.
    /// Where this device's own dyld shared cache cannot be opened, a file
    /// paired with it by default is read alone.
    public func startReading(fileAt url: URL) async throws -> RuntimeEngine {
        let startedAccessing = url.startAccessingSecurityScopedResource()
        do {
            let engine = try await startReading(try await fileToRead(at: url))
            if startedAccessing {
                if accessedURLsBySource[engine.source] == nil {
                    accessedURLsBySource[engine.source] = url
                } else {
                    // Opened again while its engine still holds the access.
                    url.stopAccessingSecurityScopedResource()
                }
            }
            return engine
        } catch {
            if startedAccessing {
                url.stopAccessingSecurityScopedResource()
            }
            throw error
        }
    }

    /// Lets `engine`'s file go once no document is on it: an engine whose file
    /// a file service reads is suspended, and reads it again when a document
    /// comes back; an engine that read its file in this process cannot be,
    /// so it is taken off the manager's list and its access to the file ends.
    public func letGoOfFile(readBy engine: RuntimeEngine) async {
        if runtimeEngineManager.readsFilesInThisProcess {
            runtimeEngineManager.terminateRuntimeEngine(for: engine.source)
            accessedURLsBySource.removeValue(forKey: engine.source)?.stopAccessingSecurityScopedResource()
            #log(.info, "Let go of \(engine.source.description, privacy: .public), read in this process")
        } else {
            await runtimeEngineManager.suspendFileEngine(engine)
        }
    }

    private func startReading(_ file: RuntimeFile) async throws -> RuntimeEngine {
        do {
            return try await runtimeEngineManager.startReading(file)
        } catch RuntimeFileError.dependencyCacheUnavailable(let reason)
            where file.dependencyCache == .systemDyldSharedCache && runtimeEngineManager.readsFilesInThisProcess {
            // A sandboxed app may not be able to open the device's cache. The
            // file alone still shows its own types.
            #log(.default, "Reading \(file.displayName, privacy: .public) without this device's dyld shared cache: \(reason, privacy: .public)")
            var fileAlone = file
            fileAlone.dependencyCache = nil
            return try await runtimeEngineManager.startReading(fileAlone)
        }
    }

    /// The file at `url` as file mode reads it: the listed one, with the
    /// cache the user paired it with, or a new one paired with the default
    /// cache.
    private func fileToRead(at url: URL) async throws -> RuntimeFile {
        var file = try await Task.detached(priority: .userInitiated) {
            try RuntimeFile(contentsOf: url)
        }.value
        if let listedFile = listedFile(withSource: file.source) {
            file = listedFile
        } else {
            file.dependencyCache = settings.file.defaultDependencyCache(for: file)
        }
        return file
    }

    private func listedFile(withSource source: RuntimeSource) -> RuntimeFile? {
        for engine in runtimeEngineManager.fileRuntimeEngines where engine.source == source {
            return runtimeEngineManager.file(of: engine)
        }
        return nil
    }
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeFileOpener.shared })
    public var runtimeFileOpener: RuntimeFileOpener
}
