import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerCommunication
import RuntimeViewerApplication
import RuntimeViewerEngineManagement
import RuntimeViewerSettings
import Dependencies
import DependenciesMacros

/// Opens a Mach-O file, a bundle, a folder or a dyld shared cache from disk: in a
/// window on an engine that reads it, in an instance of the file service of
/// its own.
///
/// `DocumentController` hands every file that is not a RuntimeViewer document
/// here — File › Open…, Open Recent and the Dock alike — and the runtime source
/// picker's Open File… and Dependency Cache open and re-pair through here too.
@Loggable
@MainActor
final class FileController {
    fileprivate static let shared = FileController()

    /// The filename extension of a RuntimeViewer document, the one kind of file
    /// not opened in file mode.
    private static let documentFilenameExtension = "runtimedocument"

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.runtimeFileOpener) private var runtimeFileOpener

    @Dependency(\.runtimeFileEngineParking) private var runtimeFileEngineParking

    private init() {}

    /// Lets a file engine's process go while no window is on it.
    func start() {
        runtimeFileEngineParking.start()
    }

    /// Whether `url` is opened in file mode rather than as a RuntimeViewer document.
    func opensFile(at url: URL) -> Bool {
        url.pathExtension.lowercased() != Self.documentFilenameExtension
    }

    /// A new document on the engine reading the file at `url`, added to the
    /// document controller and, when `display` is set, shown at once — while
    /// an instance of the file service is still reading the file, which a
    /// dyld shared cache keeps busy for a while; the window says so until it
    /// has. Throws, before any window opens, when `url` is nothing file
    /// mode reads. When the instance cannot read it, the window says why and
    /// closes once the user has acknowledged it, and Open Recent does not
    /// list the file.
    func openDocument(forFileAt url: URL, display: Bool) async throws -> Document {
        // The listed engine for the file, or a new one paired with the
        // default cache: RuntimeViewerAppCore's, shared with the iOS apps.
        let engine = try await runtimeFileOpener.startReading(fileAt: url)
        let displayName = runtimeEngineManager.file(of: engine)?.displayName ?? url.lastPathComponent
        let document = Document(runtimeEngine: engine)
        NSDocumentController.shared.addDocument(document)
        if display {
            document.makeWindowControllers()
            document.showWindows()
        }
        Task { [weak self] in
            await self?.finishOpening(document, readBy: engine, from: url, named: displayName)
        }
        return document
    }

    /// Waits for `engine` to have read its file. Then the file joins Open
    /// Recent; or, when it could not be read, `document`'s window says why
    /// and closes once the user has acknowledged it.
    private func finishOpening(_ document: Document, readBy engine: RuntimeEngine, from url: URL, named displayName: String) async {
        do {
            try await runtimeEngineManager.waitUntilFileIsRead(by: engine)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
            #log(.info, "Opened \(url.lastPathComponent, privacy: .public) from disk")
        } catch {
            #log(.error, "Could not open \(url.lastPathComponent, privacy: .public) from disk: \(error.localizedDescription, privacy: .public)")
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
}

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { FileController.shared })
    var fileController: FileController
}
