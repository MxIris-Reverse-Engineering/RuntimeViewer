import AppKit
import RuntimeViewerArchitectures
import RuntimeViewerCore
import RuntimeViewerSettings
import DependenciesMacros

/// The app's side of derived data (proposal `derived-data`): where the
/// app's services keep it, what it takes on disk, and deleting it — for the
/// Indexing settings page, through `DerivedDataClient`, and for the
/// application menu's Delete Derived Data….
///
/// Only the services read, write and clean it up; the app never opens what
/// they stored. Deleting renames the whole location aside at once and removes
/// it in the background (`RuntimeDerivedDataMaintenance.deleteAll(at:)`): a
/// service running meanwhile keeps the corpora it has in memory and writes the
/// next ones afresh.
@MainActor
final class RuntimeDerivedDataController {
    fileprivate static let shared = RuntimeDerivedDataController()

    @Dependency(\.derivedDataClient) private var derivedDataClient

    /// `nil` only for a bundle that is no RuntimeViewer application.
    private let location = RuntimeDerivedDataLocation.enclosingApplication(of: .main)

    private var measurementTask: Task<Void, Never>?

    private init() {}

    /// Makes the settings page's client this controller's: its location, and
    /// its three actions.
    func install() {
        derivedDataClient.setLocation(location?.rootURL)
        derivedDataClient.refresh = { [weak self] in
            guard let self else { return }
            measure()
        }
        derivedDataClient.showInFinder = { [weak self] in
            guard let self else { return }
            showInFinder()
        }
        derivedDataClient.delete = { [weak self] in
            guard let self else { return }
            confirmAndDeleteAll()
        }
    }

    /// Measures what the location takes, off the main actor, for the client to
    /// show; the size reads as unknown meanwhile.
    private func measure() {
        guard let location else { return }
        measurementTask?.cancel()
        derivedDataClient.setAllocatedByteCount(nil)
        measurementTask = Task { [weak self] in
            let byteCount = await Task.detached(priority: .utility) {
                RuntimeDerivedDataMaintenance.allocatedByteCount(at: location)
            }.value
            guard let self, !Task.isCancelled else { return }
            derivedDataClient.setAllocatedByteCount(byteCount)
        }
    }

    /// Reveals the location in the Finder, or the nearest folder above it that
    /// exists: nothing is written until a service first stores a corpus.
    private func showInFinder() {
        guard let location else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: location.rootURL.path) {
            NSWorkspace.shared.activateFileViewerSelecting([location.rootURL])
            return
        }
        var folderURL = location.rootURL.deletingLastPathComponent()
        while !fileManager.fileExists(atPath: folderURL.path), folderURL.pathComponents.count > 1 {
            folderURL.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(folderURL)
    }

    /// The application menu's Delete Derived Data… and the settings page's
    /// button: asks first, then deletes and measures again.
    func confirmAndDeleteAll() {
        guard let location else { return }
        let alert = NSAlert()
        alert.messageText = "Delete Derived Data?"
        alert.informativeText = "Runtime Viewer keeps the searchable interfaces of the system's images here, so that a launch on the same system with the same build reads them instead of printing them again. Deleting removes all of them; what is searchable now stays searchable, and the interfaces are printed again the next time they are needed."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try RuntimeDerivedDataMaintenance.deleteAll(at: location)
        } catch {
            NSAlert(error: error).runModal()
        }
        measure()
    }
}

// MARK: - Dependencies

extension DependencyValues {
    @DependencyEntry(liveValue: MainActor.assumeIsolated { RuntimeDerivedDataController.shared })
    var runtimeDerivedDataController: RuntimeDerivedDataController
}
