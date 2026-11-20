import AppKit
import FoundationToolbox
import RuntimeViewerCore
import RuntimeViewerApplication
import RuntimeViewerEngineManagement
import Dependencies
import DependenciesMacros

/// Opens Load Frameworks' windows (proposal `isolated-framework-loading`): Load Frameworks on My
/// Mac loads the frameworks into an instance of the framework service of their own, in a window
/// on that instance, so nothing they do lands in My Mac's process and closing the window unloads
/// them.
///
/// The window opens at once, on an engine that forwards to the instance from the start, and the
/// document's framework loader loads the frameworks once the instance answers — its page says so
/// in the window's empty pane meanwhile. Such a window joins no Open Recent and is never restored:
/// opening it again would run the frameworks again. `start()` starts
/// `RuntimeFrameworkInstanceRetirement`, which ends an instance once no window is on it.
@Loggable
@MainActor
final class FrameworkInstanceController {
    fileprivate static let shared = FrameworkInstanceController()

    @Dependency(\.runtimeEngineManager) private var runtimeEngineManager

    @Dependency(\.runtimeFrameworkInstanceRetirement) private var runtimeFrameworkInstanceRetirement

    private init() {}

    /// Ends a framework instance once no window is on it.
    func start() {
        runtimeFrameworkInstanceRetirement.start()
    }

    /// A new window on a new instance, loading `frameworkURLs` into it. When the instance cannot be
    /// started the user is told why; when it never answers, the window says so and closes once the
    /// user has acknowledged it.
    func openWindow(loadingFrameworksAt frameworkURLs: [URL]) {
        guard !frameworkURLs.isEmpty else { return }
        let instance = RuntimeFrameworkInstance(loading: frameworkURLs)
        let engine: RuntimeEngine
        do {
            engine = try runtimeEngineManager.startFrameworkInstance(instance)
        } catch {
            #log(.error, "Could not start an instance for \(instance.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            NSAlert(error: error).runModal()
            return
        }
        let document = Document(runtimeEngine: engine)
        NSDocumentController.shared.addDocument(document)
        document.makeWindowControllers()
        document.showWindows()

        let frameworkLoader = document.documentState.frameworkLoader
        Task {
            await frameworkLoader.load(frameworksAt: frameworkURLs)
        }
        Task { [weak self] in
            await self?.closeIfTheInstanceNeverAnswers(document, on: engine, named: instance.name)
        }
    }

    private func closeIfTheInstanceNeverAnswers(_ document: Document, on engine: RuntimeEngine, named name: String) async {
        do {
            try await runtimeEngineManager.waitUntilFrameworkInstanceIsReady(engine)
        } catch {
            #log(.error, "The instance for \(name, privacy: .public) never answered: \(error.localizedDescription, privacy: .public)")
            // Closed while the instance was starting: nobody is waiting to hear.
            guard NSDocumentController.shared.documents.contains(where: { $0 === document }) else { return }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "An instance for \(name) could not be started."
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
    @DependencyEntry(liveValue: MainActor.assumeIsolated { FrameworkInstanceController.shared })
    var frameworkInstanceController: FrameworkInstanceController
}
